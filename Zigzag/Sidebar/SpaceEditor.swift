import AppKit

/// The space's color wheel: a disc of small dots, each painted the very color it gives. Around the disc picks the
/// hue, and out from the middle how much of it: the rim is the color at its fullest, the middle no color at all,
/// white, a gray or black. Every dot shows at the depth the Shade slider sets. Drag a knob, or click anywhere to bring
/// the selected knob there. With two colors there are two knobs; clicking one selects it.
final class ColorWheel: NSView {
    struct Spot: Equatable {
        var hue: Double
        /// How much color, from none in the middle (0) to all of it at the rim (1).
        var amount: Double
    }

    /// Its height in the space editor, and the least it shrinks to in a short window.
    static let fullHeight: CGFloat = 200, minimumHeight: CGFloat = 140

    /// One or two: the color, or where a gradient starts and ends.
    private(set) var spots: [Spot] = [Spot(hue: 0.6, amount: 1)]
    /// How deep each knob's color is, for its fill.
    private(set) var depths: [Double] = [0.3]
    /// The knob the wheel, the Shade slider and VoiceOver act on.
    private(set) var selected = 0
    /// Called while dragging (`final` false) and once on release (`final` true), with which knob moved.
    var onChange: ((Int, Spot, Bool) -> Void)?
    /// A knob was clicked and is now the selected one.
    var onSelect: ((Int) -> Void)?

    private let dots = CALayer()
    /// A faint disc behind the dots, so the wheel stays round where its deepest colors meet a dark panel.
    private let disc = CALayer()
    private let knobs = [WheelKnob(), WheelKnob()]
    /// With a gradient, a line from one knob to the other: the two are one gradient, from here to there.
    private let link = CAShapeLayer()
    private var paintedSize: CGSize = .zero
    private var paintedDepth: Double = -1
    private var pressed: Int?
    private var shownCount = 1
    private let elements = [KnobElement(), KnobElement()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        layer?.addSublayer(dots)
        link.fillColor = nil
        link.strokeColor = NSColor.white.cgColor
        link.lineWidth = 2
        link.lineCap = .round
        link.shadowColor = NSColor.black.cgColor
        link.shadowOpacity = 0.25
        link.shadowRadius = 1.5
        link.shadowOffset = .zero
        layer?.addSublayer(link)
        knobs.forEach { layer?.addSublayer($0.layer) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Color", comment: "Accessibility label of the color wheel in the space editor."))
        for (i, element) in elements.enumerated() {
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.slider)
            element.setAccessibilityLabel(i == 0 ? String(localized: "Color", comment: "VoiceOver, in the space editor's color wheel: the knob of the space's color.") : String(localized: "Second color", comment: "VoiceOver, in the space editor's color wheel: the knob of a gradient's second color."))
            element.step = { [weak self] amount, hue in self?.nudge(i, amount: amount, hue: hue) }
            element.addHueActions()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Shows these spots, the dots at the selected one's depth; `animated` glides the knobs there, as when a preset is
    /// picked, and a second knob comes out of the first.
    func show(_ spots: [Spot], depths: [Double], selected: Int, animated: Bool) {
        self.spots = spots
        self.depths = depths
        self.selected = min(selected, spots.count - 1)
        if abs(depths[self.selected] - paintedDepth) > 0.001 { paintDots() }
        placeKnobs(animated: animated && !Tokens.Motion.reduceMotion)
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    /// Room for a whole knob, and a little more, around the dots, so one at the rim never leaves the wheel's frame.
    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 - 14 }

    func point(_ spot: Spot) -> CGPoint {
        let a = spot.hue * 2 * .pi - .pi / 2
        let r = radius * CGFloat(spot.amount)
        return CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
    }

    private func spot(at p: CGPoint, keeping hue: Double) -> Spot {
        let dx = p.x - center.x, dy = p.y - center.y
        let amount = min(Double(hypot(dx, dy) / radius), 1)
        // Right in the middle every hue is the same gray: keep the one it had.
        guard amount > 0.03 else { return Spot(hue: hue, amount: amount) }
        var h = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if h < 0 { h += 1 }
        return Spot(hue: Double(h), amount: amount)
    }

    override func layout() {
        super.layout()
        if bounds.size != paintedSize { paintDots() }
        Tokens.Motion.withoutAnimation {
            let r = radius + 6
            disc.frame = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            disc.cornerRadius = r
            effectiveAppearance.performAsCurrentDrawingAppearance { disc.backgroundColor = Tokens.Color.fieldFill.cgColor }
        }
        placeKnobs(animated: false)
    }

    /// The dots on a honeycomb, so the disc's edge reads round, painted again whenever the depth changes.
    private func paintDots() {
        paintedSize = bounds.size
        let depth = depths[min(selected, depths.count - 1)]
        paintedDepth = depth
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let step: CGFloat = 9.6, size: CGFloat = 6
        let rowStep = step * 0.866
        let rows = Int(radius / rowStep)
        for row in -rows...rows {
            let y = center.y + CGFloat(row) * rowStep
            let offset = row % 2 == 0 ? 0 : step / 2
            let columns = Int(radius / step) + 1
            for column in -columns...columns {
                let x = center.x + CGFloat(column) * step + offset
                guard hypot(x - center.x, y - center.y) <= radius - size / 2 + 0.5 else { continue }
                let spot = spot(at: CGPoint(x: x, y: y), keeping: 0)
                context.setFillColor(SpaceColor.paint(hue: spot.hue, depth: depth, tint: spot.amount).cgColor)
                context.fillEllipse(in: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
            }
        }
        Tokens.Motion.withoutAnimation {
            dots.frame = bounds
            dots.contentsScale = scale
            dots.contents = context.makeImage()
        }
    }

    private func placeKnobs(animated: Bool) {
        // A second knob just added starts on the first and slides out from it.
        if animated, spots.count > shownCount, spots.count > 1 {
            Tokens.Motion.withoutAnimation {
                knobs[1].layer.position = point(spots[0])
                knobs[1].layer.isHidden = false
            }
        }
        shownCount = spots.count
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.state)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        for (i, knob) in knobs.enumerated() {
            knob.layer.isHidden = i >= spots.count
            guard i < spots.count else { continue }
            knob.layer.position = point(spots[i])
            knob.fill = SpaceColor.paint(hue: spots[i].hue, depth: depths[i], tint: spots[i].amount)
            // With two, the one not selected sits a little smaller and lower.
            knob.isSelected = spots.count == 1 || i == selected
            knob.layer.zPosition = pressed == i ? 3 : i == selected ? 2 : 1
        }
        if spots.count > 1 {
            let path = CGMutablePath()
            path.move(to: point(spots[0]))
            path.addLine(to: point(spots[1]))
            link.frame = bounds
            link.path = path
            link.isHidden = false
        } else {
            link.isHidden = true
        }
        CATransaction.commit()
        for (i, element) in elements.enumerated() where i < spots.count {
            let p = point(spots[i])
            element.setAccessibilityFrameInParentSpace(NSRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24))
            element.setAccessibilityValue(Self.describe(spots[i]))
        }
        setAccessibilityChildren(Array(elements.prefix(spots.count)))
    }

    /// What VoiceOver says for a knob: the color's family, and how much of it.
    static func describe(_ spot: Spot) -> String {
        guard spot.amount > 0.005 else { return String(localized: "No color", comment: "VoiceOver, in the space editor's color wheel: the knob sits in the middle, white.") }
        let red = String(localized: "Red", comment: "VoiceOver, in the space editor's color wheel: a color's family.")
        let names: [(Double, String)] = [(0.04, red), (0.11, String(localized: "Orange", comment: "VoiceOver, in the space editor's color wheel: a color's family.")),
                                         (0.18, String(localized: "Yellow", comment: "VoiceOver, in the space editor's color wheel: a color's family.")), (0.43, String(localized: "Green", comment: "VoiceOver, in the space editor's color wheel: a color's family.")),
                                         (0.53, String(localized: "Teal", comment: "VoiceOver, in the space editor's color wheel: a color's family.")), (0.7, String(localized: "Blue", comment: "VoiceOver, in the space editor's color wheel: a color's family.")),
                                         (0.83, String(localized: "Purple", comment: "VoiceOver, in the space editor's color wheel: a color's family.")), (0.96, String(localized: "Pink", comment: "VoiceOver, in the space editor's color wheel: a color's family.")), (1.01, red)]
        let name = names.first { spot.hue < $0.0 }?.1 ?? red
        let amount = Int((spot.amount * 100).rounded())
        return String(localized: "\(name), \(amount) percent color", comment: "VoiceOver, in the space editor's color wheel: a knob's color family, then how much color, like “Blue, 40 percent color”.")
    }

    /// Within a knob's reach, clicking takes hold of it without moving it.
    private func knob(at p: CGPoint) -> Int? {
        let distances = spots.indices.map { (index: $0, distance: hypot(point(spots[$0]).x - p.x, point(spots[$0]).y - p.y)) }
        // Over both, the nearer one wins; the selected one only when they sit on the same spot.
        let hits = distances.filter { $0.distance <= 14 }
        guard let nearest = hits.min(by: { $0.distance < $1.distance }) else { return nil }
        return hits.first { $0.index == selected && $0.distance - nearest.distance < 1 }?.index ?? nearest.index
    }

    /// A press on the wheel: the knob it holds, how far off that knob's center, and whether it has moved it yet.
    struct Grab: Equatable {
        let index: Int
        let grip: CGPoint
        var moved: Bool
    }

    /// On a knob it takes hold of it; anywhere else the selected knob comes there.
    func press(at p: CGPoint) -> Grab {
        let held = knob(at: p)
        let index = held ?? selected
        // Grabbed off-center, a knob keeps that offset rather than jumping under the pointer.
        let grip = held.map { CGPoint(x: point(spots[$0]).x - p.x, y: point(spots[$0]).y - p.y) } ?? .zero
        if index != selected {
            selected = index
            onSelect?(index)
        }
        pressed = index
        let grab = Grab(index: index, grip: grip, moved: held == nil)
        if grab.moved { move(index, to: p, final: false) } else { placeKnobs(animated: false) }
        return grab
    }

    func drag(_ grab: inout Grab, to p: CGPoint) {
        grab.moved = true
        move(grab.index, to: CGPoint(x: p.x + grab.grip.x, y: p.y + grab.grip.y), final: false)
    }

    func release(_ grab: Grab, at p: CGPoint) {
        pressed = nil
        if grab.moved { move(grab.index, to: CGPoint(x: p.x + grab.grip.x, y: p.y + grab.grip.y), final: true) } else { placeKnobs(animated: false) }
    }

    override func mouseDown(with event: NSEvent) {
        var grab = press(at: convert(event.locationInWindow, from: nil))
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            let q = self.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.release(grab, at: q)
            } else {
                self.drag(&grab, to: q)
            }
        }
    }

    private func move(_ index: Int, to p: CGPoint, final: Bool) {
        guard index < spots.count else { return }
        var spot = spot(at: p, keeping: spots[index].hue)
        // The middle holds on a little, with a tap, so no color at all is easy to land on.
        if spot.amount < 0.07 {
            if spots[index].amount > 0 { Haptics.snap() }
            spot.amount = 0
        }
        spots[index] = spot
        placeKnobs(animated: false)
        onChange?(index, spot, final)
    }

    #if DEBUG
    func debugKnobs() -> [CGPoint] { spots.map(point) }
    #endif

    /// VoiceOver: more or less color, or the next hue around.

    // MARK: Keyboard

    private lazy var focus = KeyboardFocus(self)
    override var acceptsFirstResponder: Bool { focus.accepts }
    override var canBecomeKeyView: Bool { focus.accepts && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focus.show(true, around: focusShape)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focus.show(false, around: focusShape)
        return true
    }

    /// Around the disc itself, not the room the view gives it.
    private var focusShape: CGPath { CGPath(ellipseIn: disc.frame.insetBy(dx: -(Tokens.Metric.focusGap + Tokens.Metric.focusRing / 2), dy: -(Tokens.Metric.focusGap + Tokens.Metric.focusRing / 2)), transform: nil) }

    /// Left and right turn the selected knob's hue; up and down give it more color or less.
    override func keyDown(with event: NSEvent) {
        guard let arrow = KeyboardFocus.arrow(event) else { super.keyDown(with: event); return }
        nudge(selected, amount: arrow.vertical ? arrow.step * 0.05 : 0, hue: arrow.vertical ? 0 : arrow.step / 36)
    }

    private func nudge(_ index: Int, amount: Double, hue: Double) {
        guard index < spots.count else { return }
        var spot = spots[index]
        spot.amount = min(max(spot.amount + amount, 0), 1)
        spot.hue = (spot.hue + hue + 1).truncatingRemainder(dividingBy: 1)
        spots[index] = spot
        placeKnobs(animated: false)
        onChange?(index, spot, true)
    }
}

/// A knob on the wheel, for VoiceOver: up and down is how much color, and two actions turn it to the next hue.
nonisolated private final class KnobElement: NSAccessibilityElement {
    var step: (@MainActor @Sendable (Double, Double) -> Void)?

    func addHueActions() {
        let step = step
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Next hue", comment: "VoiceOver, in the space editor's color wheel: an action that turns the knob to the next hue.")) { MainActor.assumeIsolated { step?(0, 1 / 12) }; return true },
            NSAccessibilityCustomAction(name: String(localized: "Previous hue", comment: "VoiceOver, in the space editor's color wheel: an action that turns the knob to the previous hue.")) { MainActor.assumeIsolated { step?(0, -1 / 12) }; return true },
        ])
    }

    override func accessibilityPerformIncrement() -> Bool {
        let step = step
        MainActor.assumeIsolated { step?(0.1, 0) }
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        let step = step
        MainActor.assumeIsolated { step?(-0.1, 0) }
        return true
    }
}

/// A knob on the wheel: the chosen color in a white ring, lifted by a soft shadow.
private final class WheelKnob {
    let layer = CALayer()
    private let inner = CALayer()
    var fill: NSColor = .white { didSet { inner.backgroundColor = fill.cgColor } }
    var isSelected = true {
        didSet {
            layer.setAffineTransform(isSelected ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8))
            layer.shadowOpacity = isSelected ? 0.3 : 0.18
        }
    }

    init() {
        let size: CGFloat = 24
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        layer.backgroundColor = .white
        layer.shadowColor = .black
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        inner.frame = layer.bounds.insetBy(dx: 3.5, dy: 3.5)
        inner.cornerRadius = inner.frame.width / 2
        inner.borderWidth = Tokens.Metric.hairline
        inner.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer.addSublayer(inner)
    }
}

/// A ready-made look: one of the curated colors, which follows the Mac between its soft day and deep night shades.
struct SpaceLook {
    let name: String
    /// One of the curated colors.
    var curated: SpaceColor? = nil
    var hue: Double = 0
    /// How much color: 0 for white, grays and black.
    var tint: Double = 1
    var depth: Double
    var hue2: Double? = nil
    var depth2: Double = 0
    var angle: Double = 90
    var seeThrough: Double = 0
    var grain: Double = 0
    /// The grain's texture (`SpaceInfo.texture`): nil for fine film grain.
    var texture: String? = nil
    /// A palette look, on the palette's clear glass (`SpaceInfo.clearTint`).
    var clearTint = false
    /// Set: the hues follow the Mac, light by day and deep at night, this strong (`SpaceInfo.intensity`); `depth` unused.
    var following: Double? = nil
    /// With `following`, a palette color's own depths by day and at night (`SpaceInfo.dayDepth`, `nightDepth`).
    var day: Double? = nil
    var night: Double? = nil

    /// How it looks as a space.
    var space: SpaceInfo {
        var space = SpaceInfo(name: name, color: .graphite)
        apply(to: &space)
        return space
    }

    /// A curated color, as a preset: light by day and deep at night with the Mac, with any see-through and grain.
    /// A palette color gives its glass following the Mac, the look a new space gets.
    static func curated(_ color: SpaceColor, name: String? = nil, seeThrough: Double = 0, grain: Double = 0) -> SpaceLook {
        if let look = color.defaultLook { return look }
        return SpaceLook(name: name ?? color.name, curated: color, depth: 0, seeThrough: seeThrough, grain: grain)
    }

    /// A preset is the whole look: its see-through and grain come with it, and one without them is solid and smooth.
    func apply(to space: inout SpaceInfo) {
        space.glass = nil
        space.grain = grain > 0 ? grain : nil
        space.texture = grain > 0 ? texture : nil
        space.clearTint = clearTint && seeThrough > 0 ? true : nil
        if let curated {
            space.color = curated
            space.hue = nil
            space.tint = nil
            space.intensity = nil
            space.brightness = nil
            space.hue2 = nil
            space.tint2 = nil
            space.intensity2 = nil
            space.brightness2 = nil
            space.dayDepth = nil
            space.nightDepth = nil
            space.translucency = seeThrough > 0 ? seeThrough : nil
            space.appearance = nil
            return
        }
        if let following {
            space.hue = hue
            space.tint = abs(tint - 1) < 0.005 ? nil : tint
            space.intensity = following
            space.brightness = nil
            space.dayDepth = day
            space.nightDepth = night
            space.hue2 = hue2
            space.tint2 = hue2 == nil || abs(tint - 1) < 0.005 ? nil : tint
            space.intensity2 = hue2 == nil ? nil : following
            space.brightness2 = nil
            space.angle = hue2 == nil ? nil : angle
            space.translucency = seeThrough > 0 ? seeThrough : nil
            if seeThrough > 0 { space.clearGlass = nil }
            space.appearance = nil
            return
        }
        if tint < 0.005 {
            space.hue = nil
            space.color = .graphite
            space.tint = 0
        } else {
            space.hue = hue
            space.tint = abs(tint - 1) < 0.005 ? nil : tint
        }
        space.intensity = nil
        space.brightness = depth
        space.dayDepth = nil
        space.nightDepth = nil
        space.hue2 = hue2
        // The second color as quiet (or as rich) as the first.
        space.tint2 = hue2 == nil || abs(tint - 1) < 0.005 ? nil : tint
        space.intensity2 = nil
        space.brightness2 = hue2 == nil ? nil : depth2
        if hue2 != nil { space.angle = angle }
        space.translucency = seeThrough > 0 ? seeThrough : nil
        // A glass look is clear glass.
        if seeThrough > 0 { space.clearGlass = nil }
    }

    func matches(_ space: SpaceInfo) -> Bool {
        guard abs((space.grain ?? 0) - grain) < 0.01, (grain > 0 ? texture : nil) == ((space.grain ?? 0) > 0.01 ? space.texture : nil),
              (space.clearTint == true) == (clearTint && seeThrough > 0) else { return false }
        if let curated {
            return space.hue == nil && space.color == curated && space.brightness == nil && space.hue2 == nil
                && abs(space.seeThrough - seeThrough) < 0.01 && (curated.isNeutral || space.tintAmount > 0.99)
        }
        if let following {
            guard space.brightness == nil, space.brightness2 == nil, let h = space.hue, abs(h - hue) < 0.002, abs(space.tintAmount - tint) < 0.01,
                  abs((space.intensity ?? -1) - following) < 0.005, abs(space.seeThrough - seeThrough) < 0.01,
                  space.dayDepth == day, space.nightDepth == night else { return false }
            guard let hue2 else { return space.hue2 == nil }
            guard let h2 = space.hue2, abs(h2 - hue2) < 0.002 else { return false }
            return true
        }
        // A space saved as the old white or black (no Shade of its own) is the White or Black here.
        if space.brightness == nil, space.hue == nil, space.hue2 == nil, hue2 == nil, tint < 0.005, seeThrough == 0, !space.isSeeThrough,
           space.color == .snow || space.color == .ink {
            return depth == (space.color == .snow ? 0 : 1)
        }
        guard let b = space.brightness, abs(b - depth) < 0.005, abs(space.seeThrough - seeThrough) < 0.01 else { return false }
        if tint < 0.005 {
            guard space.isNeutral else { return false }
        } else {
            guard !space.isNeutral, let h = space.hue, abs(h - hue) < 0.002, abs(space.tintAmount - tint) < 0.01 else { return false }
        }
        guard let hue2 else { return space.hue2 == nil }
        guard let h2 = space.hue2, abs(h2 - hue2) < 0.002, abs((space.brightness2 ?? b) - depth2) < 0.005,
              abs(space.tintAmount2 - tint) < 0.01 else { return false }
        return true
    }

    static let white = SpaceLook(name: String(localized: "White", comment: "Tooltip and accessibility label of a preset look in the space editor."), tint: 0, depth: 0)
    static let black = SpaceLook(name: String(localized: "Black", comment: "Tooltip and accessibility label of a preset look in the space editor."), tint: 0, depth: 1)
    /// The palette's glass with solid white after its neutrals. Each is reachable from Custom too, black included.
    static let presets: [SpaceLook] = {
        let looks = SpaceColor.palette.compactMap(\.look)
        let neutrals = SpaceColor.neutrals.count
        return Array(looks.prefix(neutrals)) + [white] + looks.dropFirst(neutrals)
    }()
}

extension SpaceColor {
    /// A palette color's look, on clear glass, at its own depth day and night: the preset. Nil for the older colors.
    var look: SpaceLook? { paletteLook.map { SpaceLook.palette(self, $0, following: false) } }

    /// What a new space of a palette color gets: the same hues on the same glass, following the Mac between its own
    /// day and night depths, so a fresh window is light on a light Mac and deep on a dark one. Nil for the older colors.
    /// `following` is what a Zigzag from before the day and night depths shows instead.
    var defaultLook: SpaceLook? { paletteLook.map { SpaceLook.palette(self, $0, following: true) } }
}

extension SpaceLook {
    /// A palette color's look: picked in the editor at its own depth, or following the Mac as a new space has it. Its
    /// clear glass and finish come with it; `clear` false for the betas' looks from before it.
    static func palette(_ color: SpaceColor, _ p: SpaceColor.PaletteLook, following: Bool, clear: Bool = true) -> SpaceLook {
        var look = following
            ? SpaceLook(name: color.name, hue: p.hue, tint: p.tint, depth: 0, hue2: p.hue2, angle: 90, seeThrough: p.seeThrough,
                        following: p.tint < 1 ? Tokens.Frame.softFollowingIntensity : Tokens.Frame.followingIntensity, day: p.day, night: p.night)
            : SpaceLook(name: color.name, hue: p.hue, tint: p.tint, depth: p.depth, hue2: p.hue2, depth2: p.depth2 ?? p.depth, angle: 90, seeThrough: p.seeThrough)
        look.grain = p.grain
        look.texture = p.texture
        look.clearTint = clear
        return look
    }
}

/// A small checkerboard, the usual sign for see-through.
enum Checker {
    static let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
        NSColor(white: 0.97, alpha: 1).setFill()
        rect.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSRect(x: 4, y: 4, width: 4, height: 4).fill()
        return true
    }
}

/// A round swatch's ring and dot, as the space editor's presets and Reader's colors draw them: a 2pt ring at the
/// edge, the dot 2pt inside it with a hairline so white reads on a light panel and black on a dark one. Chosen, the
/// dot draws in from the ring so a gap shows; under the pointer a faint ring, and nothing moves. Call it in the
/// view's drawing appearance.
enum SwatchRing {
    static let side: CGFloat = 24

    static func draw(ring: CALayer, fill: CALayer, in bounds: CGRect, selected: Bool, hovered: Bool, chosen: NSColor) {
        ring.frame = bounds
        ring.cornerRadius = bounds.width / 2
        ring.borderWidth = 2
        ring.borderColor = (selected ? chosen : hovered ? Tokens.Color.swatchHoverRing : .clear).cgColor
        let inset: CGFloat = selected ? 3.5 : 2
        fill.frame = bounds.insetBy(dx: inset, dy: inset)
        fill.cornerRadius = fill.frame.width / 2
        fill.borderWidth = Tokens.Metric.hairline
        fill.borderColor = Tokens.Color.textTertiary.withAlphaComponent(0.3).cgColor
    }
}

/// One preset: a round swatch of the look, ringed when it's the one in use. A see-through one is a piece of its glass:
/// the color over a faint checkerboard, lit along its top. A grainy one shows its grain. Without a look it's Custom,
/// painted with the hues around the wheel.
final class LookSwatch: InteractiveView {
    let look: SpaceLook?
    private let fill = CAGradientLayer()
    private let checker = CALayer()
    private let grain = CALayer()
    private let ring = CALayer()
    /// The glass's light along its top edge.
    private let shine = CAGradientLayer()

    init(look: SpaceLook?, name: String? = nil) {
        self.look = look
        super.init(frame: .zero)
        layer?.addSublayer(ring)
        layer?.addSublayer(checker)
        layer?.addSublayer(fill)
        fill.masksToBounds = true
        checker.masksToBounds = true
        let glass = (look?.seeThrough ?? 0) > 0
        checker.isHidden = !glass
        checker.backgroundColor = NSColor(patternImage: Checker.image).cgColor
        checker.opacity = 0.45
        shine.isHidden = !glass
        shine.colors = [NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        shine.startPoint = CGPoint(x: 0.5, y: 0)
        shine.endPoint = CGPoint(x: 0.5, y: 0.55)
        grain.isHidden = (look?.grain ?? 0) == 0
        grain.backgroundColor = MaterialImages.texture(look?.texture).cgColor
        grain.opacity = Float(min(1, (look?.grain ?? 0) * 0.3))
        fill.addSublayer(grain)
        fill.addSublayer(shine)
        if look == nil {
            fill.type = .conic
            fill.startPoint = CGPoint(x: 0.5, y: 0.5)
            fill.endPoint = CGPoint(x: 0.5, y: 0)
        }
        let name = name ?? look?.name ?? ""
        toolTip = name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                SwatchRing.draw(ring: ring, fill: fill, in: bounds, selected: isSelected, hovered: isHovered,
                                chosen: Tokens.Color.textPrimary.withAlphaComponent(0.85))
                checker.frame = fill.frame
                checker.cornerRadius = fill.cornerRadius
                guard let look else {
                    fill.colors = stride(from: 0.0, through: 1, by: 1.0 / 12).map { SpaceColor.paint(hue: $0, depth: 0.3).cgColor }
                    return
                }
                let space = look.space
                // Each color at its own strength (the space's dot), so the row reads as distinct colors even in dark
                // mode, where every frame color is deep; white, grays and black as they are.
                // A designed look (a gradient, smoke) shows its real frame colors.
                let glass = look.seeThrough > 0
                // Glass shows its color as the window does, a gradient top to bottom; the checkerboard shows through.
                let start = glass ? space.background : space.isNeutral || look.curated == nil ? space.frameColor : space.swatch
                let end = glass ? space.background2 ?? start : space.frameColor2 ?? start
                let alpha = glass ? 0.8 : 1
                fill.colors = [start, end].map { $0.withAlphaComponent(alpha).cgColor }
                grain.frame = fill.bounds
                shine.frame = fill.bounds
                fill.startPoint = glass ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0.2, y: 0.1)
                fill.endPoint = glass ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0.8, y: 0.9)
            }
        }
        setAccessibilityValue(NSNumber(value: isSelected ? 1 : 0))
    }
}

/// One of the editor's sliders: a pill whose track shows what each point gives, with a white knob riding in it.
/// Shade runs light to dark in the space's own color; see-through runs from solid to clear over a checkerboard;
/// grain builds texture from smooth on the left.
final class LookSlider: NSView {
    enum Kind { case shade, seeThrough, grain }
    let kind: Kind
    var value: Double = 0 { didSet { needsLayout = true } }
    /// The colors along the track: light to dark for shade; the space's one or two colors otherwise.
    var colors: [NSColor] = [SpaceColor.sky.background] { didSet { needsLayout = true } }
    /// Called while dragging (`final` false) and once on release (`final` true).
    var onChange: ((Double, Bool) -> Void)?
    private let checker = CALayer()
    private let track = CAGradientLayer()
    private let texture = CALayer()
    private let texture2 = CALayer()
    private let ramp = CAGradientLayer()
    private let ramp2 = CAGradientLayer()
    private let knob = CALayer()
    private let stopDots = CAShapeLayer()

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        track.masksToBounds = true
        track.cornerCurve = .continuous
        track.borderWidth = Tokens.Metric.hairline
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        // The texture builds from the left, clearly: smooth at 0, heavy grain at the far end.
        // Light and dark specks, as in the window, so it shows on black as well as white.
        for (layer, mask) in [(texture, ramp), (texture2, ramp2)] where kind == .grain {
            layer.backgroundColor = MaterialImages.grain.cgColor
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.cgColor]
            layer.mask = mask
            track.addSublayer(layer)
        }
        checker.masksToBounds = true
        checker.isHidden = kind != .seeThrough
        checker.backgroundColor = NSColor(patternImage: Checker.image).cgColor
        layer?.addSublayer(checker)
        layer?.addSublayer(track)
        track.addSublayer(stopDots)
        // A white disc riding inside the track.
        knob.backgroundColor = .white
        knob.shadowOpacity = 1
        knob.shadowRadius = 3
        knob.shadowOffset = CGSize(width: 0, height: 1)
        knob.borderWidth = Tokens.Metric.hairline
        knob.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.addSublayer(knob)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(kind == .shade ? String(localized: "Shade", comment: "A slider in the space editor: how light or deep the color is.")
                              : kind == .seeThrough ? String(localized: "See-through", comment: "A slider in the space editor: how much of the desktop shows through the window.")
                              : String(localized: "Grain", comment: "A slider in the space editor: how much film grain the color has."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var knobWidth: CGFloat { bounds.height - 8 }
    private var inset: CGFloat { 4 + knobWidth / 2 }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            track.frame = bounds
            track.cornerRadius = track.frame.height / 2
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let first = colors.first ?? .white
                switch kind {
                case .shade: track.colors = colors.map(\.cgColor)
                // Solid on the left, and as thin as the frame gets on the right.
                case .seeThrough: track.colors = [first.withAlphaComponent(1).cgColor, first.withAlphaComponent(0.2).cgColor]
                case .grain: track.colors = [first.cgColor, (colors.last ?? first).cgColor]
                }
                track.borderColor = Tokens.Color.panelEdge.cgColor
                knob.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
            }
            checker.frame = track.frame
            checker.cornerRadius = track.cornerRadius
            for (layer, mask) in [(texture, ramp), (texture2, ramp2)] {
                layer.frame = track.bounds
                mask.frame = layer.bounds
            }
            let x = inset + CGFloat(value) * (bounds.width - inset * 2)
            knob.bounds = CGRect(x: 0, y: 0, width: knobWidth, height: knobWidth)
            knob.position = CGPoint(x: x, y: bounds.height / 2)
            knob.cornerRadius = knobWidth / 2
            stopDots.frame = track.bounds
            let path = CGMutablePath()
            for stop in stops.dropFirst().dropLast() {
                let sx = inset + CGFloat(stop) * (bounds.width - inset * 2)
                path.addEllipse(in: CGRect(x: sx - 1.5, y: bounds.height / 2 - 1.5, width: 3, height: 3))
            }
            stopDots.path = path
            stopDots.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        }
        // Held, the knob swells a little under your finger.
        knob.setAffineTransform(pressed ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity)
        let amount = Int((value * 100).rounded())
        let percent = String(localized: "\(amount) percent", comment: "VoiceOver, a slider's value in the space editor, like “40 percent”.")
        switch kind {
        case .shade: setAccessibilityValue(value < 0.01 ? String(localized: "Lightest", comment: "VoiceOver, the Shade slider's value at its lightest.") : value > 0.99 ? String(localized: "Darkest", comment: "VoiceOver, the Shade slider's value at its deepest.")
                                           : String(localized: "\(amount) percent dark", comment: "VoiceOver, the Shade slider's value, like “40 percent dark”."))
        case .seeThrough: setAccessibilityValue(value < 0.01 ? String(localized: "Solid", comment: "VoiceOver, the See-through slider's value when nothing shows through.") : percent)
        case .grain: setAccessibilityValue(value < 0.01 ? String(localized: "Smooth", comment: "VoiceOver, the Grain slider's value with no grain.") : percent)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Stops it settles into, with a tap at each, so it feels like a real control with some resistance. Shade runs
    /// smooth: every depth is as good as the next.
    private var stops: [Double] { kind == .shade ? [] : [0, 0.25, 0.5, 0.75, 1] }
    private var lastStop: Double?

    private func value(at event: NSEvent) -> Double {
        let x = convert(event.locationInWindow, from: nil).x
        let v = Double(min(max((x - inset) / (bounds.width - inset * 2), 0), 1))
        if let stop = stops.first(where: { abs($0 - v) < 0.045 }) {
            if stop != lastStop { Haptics.snap() }
            lastStop = stop
            return stop
        }
        lastStop = nil
        return v
    }

    private var pressed = false { didSet { needsLayout = true } }

    override func mouseDown(with event: NSEvent) {
        lastStop = stops.first { abs($0 - value) < 0.001 }
        pressed = true
        value = value(at: event)
        layoutSubtreeIfNeeded()
        onChange?(value, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            self.value = self.value(at: event)
            self.layoutSubtreeIfNeeded()
            if event.type == .leftMouseUp {
                stop.pointee = true
                self.pressed = false
                self.onChange?(self.value, true)
            } else {
                self.onChange?(self.value, false)
            }
        }
    }

    override func accessibilityPerformIncrement() -> Bool { step(0.1) }
    override func accessibilityPerformDecrement() -> Bool { step(-0.1) }


    // MARK: Keyboard

    private lazy var focus = KeyboardFocus(self)
    override var acceptsFirstResponder: Bool { focus.accepts }
    override var canBecomeKeyView: Bool { focus.accepts && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focus.show(true, around: focusShape)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focus.show(false, around: focusShape)
        return true
    }

    private var focusShape: CGPath {
        let rect = bounds.insetBy(dx: -(Tokens.Metric.focusGap + Tokens.Metric.focusRing / 2), dy: -(Tokens.Metric.focusGap + Tokens.Metric.focusRing / 2))
        return CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
    }

    /// Any arrow moves it a twentieth of the way.
    override func keyDown(with event: NSEvent) {
        guard let arrow = KeyboardFocus.arrow(event) else { super.keyDown(with: event); return }
        _ = step(arrow.step * 0.05)
    }

    private func step(_ delta: Double) -> Bool {
        value = min(max(value + delta, 0), 1)
        onChange?(value, true)
        return true
    }
}

/// Which way the gradient runs: a small knob you turn. A white thumb, the sliders' own, with a notch toward where the
/// gradient goes, set in a ring of the gradient itself that turns with it, inside a fine ring of ticks with the one
/// it points at lit. A soft click at each of the eight main directions. Drag around it, or click where it should point.
final class DirectionKnob: NSView {
    var angle: Double = 45 { didSet { needsLayout = true } }
    /// Where the gradient starts and ends, shown on the ring.
    var colors: (NSColor, NSColor) = (.white, .black) { didSet { needsLayout = true } }
    var onChange: ((Double, Bool) -> Void)?
    private let ticks = CAShapeLayer()
    private let lit = CAShapeLayer()
    private let ring = CAGradientLayer()
    private let thumb = CALayer()
    private let notch = CALayer()
    private var lastDetent: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(ticks)
        layer?.addSublayer(lit)
        ring.masksToBounds = true
        ring.borderWidth = Tokens.Metric.hairline
        layer?.addSublayer(ring)
        // The same white disc as a slider's knob.
        thumb.backgroundColor = .white
        thumb.shadowOpacity = 1
        thumb.shadowRadius = 3
        thumb.shadowOffset = CGSize(width: 0, height: 1)
        thumb.borderWidth = Tokens.Metric.hairline
        thumb.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.addSublayer(thumb)
        notch.backgroundColor = NSColor(white: 0.32, alpha: 1).cgColor
        layer?.addSublayer(notch)
        toolTip = String(localized: "Gradient Direction", comment: "Tooltip and accessibility label of the dial that turns a space's gradient, in the space editor.")
        setAccessibilityRole(.slider)
        setAccessibilityLabel(String(localized: "Gradient Direction", comment: "Tooltip and accessibility label of the dial that turns a space's gradient, in the space editor."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2
        let ringRadius = outer - 5
        let thumbRadius = ringRadius - 3.5
        let a = angle * .pi / 180
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ticks.fillColor = Tokens.Color.textTertiary.withAlphaComponent(0.6).cgColor
                lit.fillColor = Tokens.Color.textPrimary.cgColor
                ring.borderColor = Tokens.Color.panelEdge.cgColor
                ring.colors = [colors.0.cgColor, colors.1.cgColor]
                thumb.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
            }
            ring.frame = CGRect(x: c.x - ringRadius, y: c.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            ring.cornerRadius = ringRadius
            // The ring runs the way the window does: from the first color to the second, along the angle.
            let dx = cos(a) / 2, dy = sin(a) / 2
            ring.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            ring.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
            thumb.frame = CGRect(x: c.x - thumbRadius, y: c.y - thumbRadius, width: thumbRadius * 2, height: thumbRadius * 2)
            thumb.cornerRadius = thumbRadius
            let ticksPath = CGMutablePath(), litPath = CGMutablePath()
            let nearest = Int((angle / 15).rounded()) % 24
            for i in 0..<24 {
                let t = Double(i) / 24 * 2 * .pi
                let size: CGFloat = i % 3 == 0 ? 1.1 : 0.7
                let p = CGPoint(x: c.x + cos(t) * (outer - 1.5), y: c.y + sin(t) * (outer - 1.5))
                let dot = CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)
                if i == nearest { litPath.addEllipse(in: dot.insetBy(dx: -0.5, dy: -0.5)) } else { ticksPath.addEllipse(in: dot) }
            }
            ticks.path = ticksPath
            ticks.frame = bounds
            lit.path = litPath
            lit.frame = bounds
            // The notch turns with the knob, from near the middle out toward the second color.
            let length = thumbRadius * 0.6
            notch.bounds = CGRect(x: 0, y: 0, width: length, height: 2)
            notch.cornerRadius = 1
            let reach = thumbRadius - 2.5 - length / 2
            notch.position = CGPoint(x: c.x + cos(a) * reach, y: c.y + sin(a) * reach)
            notch.setAffineTransform(CGAffineTransform(rotationAngle: a))
        }
        let degrees = Int(angle)
        setAccessibilityValue(String(localized: "\(degrees) degrees", comment: "VoiceOver, the gradient dial's angle in the space editor, like “90 degrees”."))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func angle(at event: NSEvent) -> Double {
        let p = convert(event.locationInWindow, from: nil)
        var a = atan2(p.y - bounds.midY, p.x - bounds.midX) * 180 / .pi
        if a < 0 { a += 360 }
        // Settles on the eight main directions when close.
        let nearest = (a / 45).rounded() * 45
        return abs(nearest - a) < 8 ? nearest.truncatingRemainder(dividingBy: 360) : a
    }

    /// A light tap under your finger at each main direction, as a detent would give.
    private func detent() {
        let step = Int((angle / 45).rounded()) % 8
        guard angle.truncatingRemainder(dividingBy: 45) == 0, step != lastDetent else { return }
        lastDetent = step
        Haptics.snap()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        lastDetent = Int((angle / 45).rounded()) % 8
        angle = angle(at: event)
        detent()
        onChange?(angle, false)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            Tokens.Motion.withoutAnimation {
                self.angle = self.angle(at: event)
                self.layoutSubtreeIfNeeded()
            }
            self.detent()
            if event.type == .leftMouseUp {
                stop.pointee = true
                NSCursor.pop()
                self.onChange?(self.angle, true)
            } else {
                self.onChange?(self.angle, false)
            }
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    // MARK: Keyboard

    private lazy var focus = KeyboardFocus(self)
    override var acceptsFirstResponder: Bool { focus.accepts }
    override var canBecomeKeyView: Bool { focus.accepts && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        focus.show(true, around: focusShape)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        focus.show(false, around: focusShape)
        return true
    }

    private var focusShape: CGPath { CGPath(ellipseIn: bounds.insetBy(dx: -(Tokens.Metric.focusGap + Tokens.Metric.focusRing / 2), dy: -(Tokens.Metric.focusGap + Tokens.Metric.focusRing / 2)), transform: nil) }

    /// Any arrow turns it a step of 15°.
    override func keyDown(with event: NSEvent) {
        guard let arrow = KeyboardFocus.arrow(event) else { super.keyDown(with: event); return }
        angle = (angle + arrow.step * 15 + 360).truncatingRemainder(dividingBy: 360)
        onChange?(angle, true)
    }

    override func accessibilityPerformIncrement() -> Bool { angle = (angle + 45).truncatingRemainder(dividingBy: 360); onChange?(angle, true); return true }
    override func accessibilityPerformDecrement() -> Bool { angle = (angle + 315).truncatingRemainder(dividingBy: 360); onChange?(angle, true); return true }
}

/// One of the space's own colors in the Colors row: a round swatch like a preset's, ringed when its knob is the
/// selected one on the wheel. The second shows a small × on hover that takes it away.
final class ColorChip: InteractiveView {
    var color: NSColor = .white { didSet { stateDidChange(animated: false) } }
    /// Set for the second color: the × that removes it, and the same for VoiceOver.
    var onRemove: (() -> Void)? {
        didSet {
            setAccessibilityCustomActions(onRemove == nil ? nil : [
                NSAccessibilityCustomAction(name: String(localized: "Remove second color", comment: "VoiceOver action on the second color's chip in the space editor: ends the gradient.")) { [weak self] in self?.onRemove?(); return true },
            ])
        }
    }
    private let fill = CALayer()
    private let ring = CALayer()
    private let badge = RemoveBadge()

    init(label: String) {
        super.init(frame: .zero)
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
        layer?.addSublayer(fill)
        layer?.addSublayer(badge.layer)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    /// Whether a click landed on the ×.
    func hitsBadge(_ event: NSEvent) -> Bool {
        onRemove != nil && badge.hits(convert(event.locationInWindow, from: nil))
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.frame = bounds
                ring.cornerRadius = bounds.width / 2
                ring.borderWidth = 2
                ring.borderColor = (isSelected ? Tokens.Color.textPrimary : isHovered ? Tokens.Color.swatchHoverRing : .clear).cgColor
                let inset: CGFloat = isSelected ? 4 : 1.5
                fill.frame = bounds.insetBy(dx: inset, dy: inset)
                fill.cornerRadius = fill.frame.width / 2
                fill.backgroundColor = color.cgColor
                fill.borderWidth = Tokens.Metric.hairline
                fill.borderColor = Tokens.Color.textTertiary.withAlphaComponent(0.3).cgColor
            }
            badge.place(in: bounds)
            badge.isHidden = onRemove == nil || !isHovered
        }
        setAccessibilityValue(NSNumber(value: isSelected ? 1 : 0))
    }
}

/// The × on a chip's corner that removes what the chip holds.
final class RemoveBadge {
    let layer = CALayer()
    private static let side: CGFloat = 14
    private let cross = CAShapeLayer()
    var isHidden: Bool {
        get { layer.isHidden }
        set { layer.isHidden = newValue }
    }

    init() {
        layer.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
        layer.borderColor = NSColor.white.cgColor
        layer.borderWidth = 1.5
        layer.isHidden = true
        cross.strokeColor = NSColor.white.cgColor
        cross.lineWidth = 1.4
        cross.lineCap = .round
        layer.addSublayer(cross)
    }

    /// On the top right corner of `bounds`, a little past it.
    func place(in bounds: CGRect) {
        let side = Self.side, m = side / 2, r: CGFloat = 2.6
        layer.frame = CGRect(x: bounds.maxX - side + 3, y: -3, width: side, height: side)
        layer.cornerRadius = m
        let path = CGMutablePath()
        path.move(to: CGPoint(x: m - r, y: m - r))
        path.addLine(to: CGPoint(x: m + r, y: m + r))
        path.move(to: CGPoint(x: m + r, y: m - r))
        path.addLine(to: CGPoint(x: m - r, y: m + r))
        cross.path = path
        cross.frame = layer.bounds
    }

    /// Whether `point` (in the superview's coordinates) is on it or close by.
    func hits(_ point: CGPoint) -> Bool { !layer.isHidden && layer.frame.insetBy(dx: -2, dy: -2).contains(point) }
}

/// The background picture swatch: an empty slot, or the picture with a remove button on hover.
final class BackgroundSwatch: InteractiveView {
    var image: CGImage? {
        didSet {
            stateDidChange(animated: false)
            setAccessibilityCustomActions(image == nil ? nil : [
                NSAccessibilityCustomAction(name: Self.removeTitle) { [weak self] in self?.onRemove?(); return true },
            ])
        }
    }
    var onRemove: (() -> Void)?
    private let outline = CAShapeLayer()
    private let picture = CALayer()
    private let glyph = NSImageView()
    private let badge = RemoveBadge()
    private static let removeTitle = String(localized: "Remove", comment: "VoiceOver action on the Background swatch in a space's editor: takes the picture off the space's empty page and deletes Zigzag's copy of it.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.masksToBounds = false
        outline.fillColor = nil
        outline.lineWidth = 1.2
        outline.lineDashPattern = [3, 2.5]
        layer?.addSublayer(outline)
        picture.masksToBounds = true
        picture.contentsGravity = .resizeAspectFill
        picture.borderWidth = Tokens.Metric.hairline
        layer?.addSublayer(picture)
        glyph.image = Tokens.Symbol.image("photo", size: Tokens.Symbol.inline)
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        layer?.addSublayer(badge.layer)
        let title = String(localized: "Background", comment: "Tooltip and accessibility label of the swatch in a space's editor that chooses the picture its empty page shows.")
        toolTip = title
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whether a click landed on the ×.
    func hitsBadge(_ event: NSEvent) -> Bool { badge.hits(convert(event.locationInWindow, from: nil)) }

    /// Delete with keyboard focus here acts like the ×.
    override func keyDown(with event: NSEvent) {
        if hasKeyboardFocus, image != nil, [51, 117].contains(event.keyCode) { onRemove?(); return }
        super.keyDown(with: event)
    }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // The slot stays its size under the pointer; its outline and glyph darken.
                let circle = bounds.insetBy(dx: 2, dy: 2)
                outline.frame = bounds
                outline.path = CGPath(ellipseIn: circle.insetBy(dx: 0.6, dy: 0.6), transform: nil)
                outline.strokeColor = (isHovered ? Tokens.Color.textSecondary : Tokens.Color.textTertiary).cgColor
                outline.isHidden = image != nil
                picture.frame = circle
                picture.cornerRadius = circle.width / 2
                picture.contents = image
                picture.isHidden = image == nil
                picture.borderColor = Tokens.Color.textTertiary.withAlphaComponent(0.3).cgColor
                glyph.contentTintColor = isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
            }
            glyph.frame = bounds
            glyph.isHidden = image != nil
            badge.place(in: bounds)
            badge.isHidden = image == nil || !isHovered
        }
    }
}

/// An empty round slot with a +, beside the space's color: click it for a second color and a gradient.
final class AddColorSlot: InteractiveView {
    private let outline = CAShapeLayer()
    private let plus = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        outline.fillColor = nil
        outline.lineWidth = 1.2
        outline.lineDashPattern = [3, 2.5]
        layer?.addSublayer(outline)
        plus.lineWidth = 1.5
        plus.lineCap = .round
        layer?.addSublayer(plus)
        toolTip = String(localized: "Add Second Color", comment: "Tooltip and accessibility label of the slot that adds a gradient's second color, in the space editor.")
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Add Second Color", comment: "Tooltip and accessibility label of the slot that adds a gradient's second color, in the space editor."))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
                outline.frame = bounds
                outline.path = CGPath(ellipseIn: rect, transform: nil)
                outline.strokeColor = (isHovered ? Tokens.Color.textSecondary : Tokens.Color.textTertiary).cgColor
                outline.fillColor = isHovered ? Tokens.Color.fieldFill.cgColor : nil
                plus.strokeColor = (isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary).cgColor
            }
            let path = CGMutablePath()
            let c = CGPoint(x: bounds.midX, y: bounds.midY), r: CGFloat = 4.5
            path.move(to: CGPoint(x: c.x - r, y: c.y))
            path.addLine(to: CGPoint(x: c.x + r, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x, y: c.y + r))
            plus.frame = bounds
            plus.path = path
        }
    }
}

/// A quiet heading that folds what's under it away: its name, and a chevron that turns as it opens.
final class DisclosureRow: InteractiveView {
    private let label: Label
    private let chevron = NSImageView()
    var isOpen = false { didSet { if oldValue != isOpen { turn(animated: true) } } }

    init(title: String) {
        label = Label(title, font: Tokens.Font.body(.light), color: Tokens.Color.textSecondary)
        super.init(frame: .zero)
        chevron.image = Tokens.Symbol.image("chevron.right", size: Tokens.Symbol.inline)
        chevron.imageScaling = .scaleNone
        chevron.wantsLayer = true
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its name and the chevron after it, and no more.
    var fittingWidth: CGFloat { ceil(label.textWidth) + Tokens.Space.x1 + Tokens.Space.x4 }
    var capHeight: CGFloat { label.font?.capHeight ?? 0 }

    override func layout() {
        super.layout()
        let h = label.lineHeight
        label.frame = NSRect(x: 0, y: label.centeredY(in: bounds.height), width: label.textWidth, height: h)
        let side = Tokens.Space.x4
        chevron.frame = NSRect(x: label.frame.maxX + Tokens.Space.x1, y: (bounds.height - side) / 2, width: side, height: side)
        turn(animated: false)
    }

    /// The chevron points right when folded and down when open, as the space name's does.
    private func turn(animated: Bool) {
        chevron.image = Tokens.Symbol.image(isOpen ? "chevron.down" : "chevron.right", size: Tokens.Symbol.inline)
        setAccessibilityValue(isOpen ? 1 : 0)
    }

    override func stateDidChange(animated: Bool) {
        label.textColor = isHovered ? Tokens.Color.textPrimary : Tokens.Color.textSecondary
        chevron.contentTintColor = label.textColor
    }
}

/// The space's look: swatches (Default, presets, picture, Custom), the wheel and Shade under Custom, and Effects.
/// `onPreview` fires while dragging, `onCommit` on release or pick.
final class SpaceLookEditor: NSView {
    private let wheel = ColorWheel()
    private let colorsLabel = SpaceLookEditor.rowLabel(String(localized: "Gradient", comment: "A row's label in the space editor's Effects: the space's one or two colors."))
    /// The space's colors, one per knob on the wheel; clicking one selects its knob.
    private let chips = [ColorChip(label: String(localized: "Color", comment: "Accessibility label of the chip of the space's color, in the space editor.")),
                         ColorChip(label: String(localized: "Second color", comment: "Accessibility label of the chip of a gradient's second color, in the space editor."))]
    /// Adds a second color for a gradient; the second chip's × takes it away again.
    private let addSlot = AddColorSlot()
    private let dial = DirectionKnob()
    /// The colors the space was made with, following the Mac.
    private let defaultSwatch: LookSwatch
    private let swatches = SpaceLook.presets.map { LookSwatch(look: $0) }
    /// The picture the space's empty page shows; the panel picks and removes it.
    let backgroundSwatch = BackgroundSwatch()
    /// Ringed when the colors match no other swatch; click shows the wheel and Shade.
    private let customSwatch = LookSwatch(look: nil, name: String(localized: "Custom", comment: "Tooltip and accessibility label of the last swatch in a space's editor: shows the color wheel for a color of your own."))
    private var showsCustom = false
    /// In the row's order, for the arrow keys.
    private var tiles: [InteractiveView] { [defaultSwatch] + swatches + [backgroundSwatch, customSwatch] }
    /// Gradient, see-through and grain: there when you want them, folded away until then.
    private let effects = DisclosureRow(title: String(localized: "Effects", comment: "A folding section of the space editor: gradient, see-through and grain."))
    private var showsEffects = false
    /// Whether the Frosted or Clear row is out (a see-through space with Effects open).
    private var showsGlass = false
    private let shadeLabel = SpaceLookEditor.rowLabel(String(localized: "Shade", comment: "A slider in the space editor: how light or deep the color is."))
    private let shadeSlider = LookSlider(.shade)
    private let clearLabel = SpaceLookEditor.rowLabel(String(localized: "See-through", comment: "A slider in the space editor: how much of the desktop shows through the window."))
    private let clearSlider = LookSlider(.seeThrough)
    /// Frosted or clear glass, for a see-through space.
    private let glassLabel = SpaceLookEditor.rowLabel(String(localized: "Glass", comment: "A row in the space editor's Effects, for a see-through space: clear or frosted glass."))
    private let glassSwitch = SlidingSwitch([.text(String(localized: "glass.clear", defaultValue: "Clear", comment: "In the space editor, for a see-through space: clear glass, the desktop sharp behind it. Not the sidebar's Clear button.")),
                                                 .text(String(localized: "Frosted", comment: "In the space editor, for a see-through space: frosted glass, the desktop blurred behind it."))])
    /// Under Glass while Clear is chosen but battery saving shows it frosted.
    private let glassNote: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = Tokens.Font.detail()
        label.textColor = Tokens.Color.textSecondary
        label.isSelectable = false
        return label
    }()
    private var glassNoteText: String?
    private let grainLabel = SpaceLookEditor.rowLabel(String(localized: "Grain", comment: "A slider in the space editor: how much film grain the color has."))
    private let grainSlider = LookSlider(.grain)
    /// The color the space was made with, which `defaultSwatch` goes back to.
    private let defaultColor: SpaceColor

    var onPreview: ((SpaceInfo) -> Void)?
    var onCommit: ((SpaceInfo) -> Void)?
    /// The editor grew or shrank (Custom or Effects opened or folded).
    var onResize: (() -> Void)?

    /// The space as the editor has it right now.
    private var draft: SpaceInfo
    /// As it was when the editor opened, or with its default colors once they're put back: what a space that
    /// follows the Mac keeps.
    private var original: SpaceInfo
    /// A space never given a color follows the Mac, light by day and dark at night, until you choose one.
    private var colorChosen: Bool
    /// Which color the wheel's selected knob is, and Shade shows: 0, or 1 for a gradient's second.
    private var selected = 0

    /// `dark`: whether the window looks dark right now, for where a space that follows the Mac starts.
    init(space: SpaceInfo, defaultColor: SpaceColor, dark: Bool) {
        let space = space.upgraded
        isDark = dark
        self.defaultColor = defaultColor
        original = space
        draft = space
        colorChosen = space.brightness != nil
        defaultSwatch = LookSwatch(look: .curated(defaultColor), name: String(localized: "Use Default Colors", comment: "Item in a space's context menu, and tooltip of the first swatch in the space editor: puts back the colors the space had when it was made."))
        super.init(frame: .zero)
        if draft.brightness == nil { draft.brightness = Self.startingDepth(space, dark: dark) }
        let views: [NSView] = [wheel, colorsLabel, addSlot, dial, shadeLabel, shadeSlider, clearLabel, clearSlider, glassLabel, glassSwitch, glassNote, grainLabel, grainSlider, effects]
        // A palette look's own glass and gradient aren't effects chosen.
        let ownGlass = (SpaceLook.presets.contains { $0.seeThrough > 0 && $0.matches(space) }
            || SpaceColor.palette.contains { $0.defaultLook?.matches(space) == true }) && space.clearGlass != false
        showsEffects = !ownGlass && (space.hue2 != nil || space.isSeeThrough) || (space.grain ?? 0) > 0.01
        (tiles + views + chips).forEach { addSubview($0) }

        wheel.onChange = { [weak self] index, spot, final in
            guard let self else { return }
            let tint = spot.amount > 0.995 ? nil : spot.amount
            if index == 0 {
                self.draft.hue = spot.hue
                self.draft.tint = tint
            } else {
                self.draft.hue2 = spot.hue
                self.draft.tint2 = tint
            }
            self.draft.intensity = nil
            self.draft.intensity2 = nil
            self.draft.dayDepth = nil
            self.draft.nightDepth = nil
            // A color from the wheel is custom, on a custom color's glass, as `Library.setHue` has it.
            self.draft.clearTint = nil
            self.colorChosen = true
            self.changed(final: final, animated: false)
        }
        wheel.onSelect = { [weak self] index in
            self?.selected = index
            self?.sync(animated: false)
        }
        for (i, chip) in chips.enumerated() {
            chip.onClick = { [weak self, weak chip] event in
                guard let self else { return }
                if chip?.hitsBadge(event) == true { self.toggleSecondColor(); return }
                guard self.selected != i else { return }
                self.selected = i
                self.sync(animated: false)
            }
        }
        chips[1].onRemove = { [weak self] in self?.toggleSecondColor() }
        addSlot.onClick = { [weak self] _ in self?.toggleSecondColor() }
        for swatch in swatches {
            swatch.onClick = { [weak self, weak swatch] _ in
                guard let self, let look = swatch?.look else { return }
                look.apply(to: &self.draft)
                self.selected = 0
                if look.curated != nil {
                    // A palette color follows the Mac, as the default colors do.
                    self.original = self.draft
                    self.draft.brightness = Self.startingDepth(self.draft, dark: self.isDark)
                    self.colorChosen = false
                } else {
                    self.colorChosen = true
                }
                self.changed(final: true, animated: true)
            }
        }
        defaultSwatch.onClick = { [weak self] _ in self?.useDefaultColors() }
        customSwatch.onClick = { [weak self] _ in self?.showCustom() }
        effects.onClick = { [weak self] _ in
            guard let self else { return }
            self.showsEffects.toggle()
            self.sync(animated: true)
            self.onResize?()
        }
        shadeSlider.onChange = { [weak self] value, final in self?.shade(to: value, final: final) }
        clearSlider.onChange = { [weak self] value, final in
            guard let self else { return }
            self.draft.translucency = value > 0.005 ? value : nil
            self.changed(final: final, animated: false)
        }
        glassSwitch.onChange = { [weak self] index in
            guard let self else { return }
            self.draft.clearGlass = index == 0 ? nil : false
            self.changed(final: true, animated: false)
        }
        grainSlider.onChange = { [weak self] grain, final in
            guard let self else { return }
            self.draft.grain = grain > 0.01 ? grain : nil
            self.changed(final: final, animated: false)
        }
        dial.onChange = { [weak self] angle, final in
            guard let self else { return }
            self.draft.angle = angle
            self.changed(final: final, animated: false)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(powerSavingChanged), name: PowerSaving.changed, object: nil)
        sync(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func powerSavingChanged() { sync(animated: false) }

    /// What the note under Glass says: why Clear shows as frosted right now, or nil while it doesn't.
    static func glassNote(clearChosen: Bool, onBattery: Bool, lowPowerMode: Bool) -> String? {
        guard clearChosen else { return nil }
        if onBattery {
            return String(localized: "On battery, Clear shows as Frosted to save power.", comment: "Under Glass in the space editor, while the Mac runs on its battery: clear glass shows as frosted until it's plugged in.")
        }
        if lowPowerMode {
            return String(localized: "In Low Power Mode, Clear shows as Frosted to save power.", comment: "Under Glass in the space editor, while Low Power Mode is on: clear glass shows as frosted until it's off.")
        }
        return nil
    }

    /// Left and right move keyboard focus along the swatches.
    override func keyDown(with event: NSEvent) {
        let tiles = self.tiles
        guard let arrow = KeyboardFocus.arrow(event), !arrow.vertical,
              let index = tiles.firstIndex(where: { $0 === window?.firstResponder }) else { super.keyDown(with: event); return }
        window?.makeFirstResponder(tiles[(index + Int(arrow.step) + tiles.count) % tiles.count])
    }

    static func rowLabel(_ text: String) -> Label {
        Label(text, font: Tokens.Font.body(.light), color: Tokens.Color.textSecondary)
    }

    /// Where the knob starts for a space that follows the Mac: about how it looks right now, so nothing jumps.
    private static func startingDepth(_ space: SpaceInfo, dark: Bool) -> Double {
        // White and black are the two ends of Shade.
        if space.hue == nil, space.brightness == nil, space.color == .snow { return 0 }
        if space.hue == nil, space.brightness == nil, space.color == .ink { return 1 }
        if space.isNeutral { return dark ? 0.9 : 0.06 }
        if let day = space.dayDepth, let night = space.nightDepth { return dark ? night : day }
        let strength = space.intensity ?? SpaceColor.defaultIntensity
        return dark ? 0.86 : 0.06 + 0.2 * strength
    }

    // MARK: Changing it

    /// The space as it should be saved or shown: untouched colors keep following the Mac.
    var look: SpaceInfo {
        var space = draft
        if !colorChosen {
            space.brightness = original.brightness
            space.brightness2 = original.brightness2
            space.appearance = original.appearance
            return space
        }
        // Light or dark: whichever text reads better on it.
        space.appearance = space.readableAppearance
        return space
    }

    private func depth(_ index: Int) -> Double {
        // A space that follows the Mac shows on the wheel at about the shade it has right now.
        let follows = Self.startingDepth(draft, dark: isDark)
        return index == 0 ? draft.brightness ?? follows : draft.brightness2 ?? draft.brightness ?? follows
    }
    /// Whether the window is dark, for placing a system-following space on Shade.
    private var isDark: Bool
    /// Where Shade shows the selected color, from 0 (lightest) to 1 (darkest).
    var shownDepth: Double { depth(selected) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        follow(dark: effectiveAppearance.isDark)
    }

    /// Appearance changed with the editor open: move a system-following space's wheel and Shade to its current color.
    func follow(dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        guard !colorChosen else { return }
        draft.brightness = Self.startingDepth(original, dark: dark)
        sync(animated: false)
    }

    /// Lighter or darker. With two colors both move together, keeping the step between them; holding Option moves
    /// only the selected one.
    private func shade(to value: Double, final: Bool) {
        if draft.hue2 == nil || NSEvent.modifierFlags.contains(.option) {
            if selected == 0 { draft.brightness = value } else { draft.brightness2 = value }
        } else {
            let first = depth(0), second = depth(1)
            let delta = min(max(value - depth(selected), -min(first, second)), 1 - max(first, second))
            draft.brightness = first + delta
            draft.brightness2 = second + delta
        }
        draft.dayDepth = nil
        draft.nightDepth = nil
        colorChosen = true
        changed(final: final, animated: false)
    }

    /// The + slot: a second color, the first's neighbor on the wheel and a step deeper, so the gradient reads at once.
    /// The second chip's × takes it away.
    private func toggleSecondColor() {
        if draft.hue2 == nil {
            // From white, a gray or black, the second is Zigzag's blue, so there's something to fade into.
            draft.hue2 = draft.isNeutral ? 0.6 : (draft.baseHue + 0.22).truncatingRemainder(dividingBy: 1)
            draft.tint2 = draft.isNeutral ? nil : draft.tint
            let first = depth(0)
            draft.brightness2 = first < 0.6 ? first + 0.16 : first - 0.16
            draft.angle = draft.angle ?? 90
            selected = 1
        } else {
            draft.hue2 = nil
            draft.tint2 = nil
            draft.brightness2 = nil
            draft.intensity2 = nil
            selected = 0
        }
        draft.intensity = nil
        draft.dayDepth = nil
        draft.nightDepth = nil
        colorChosen = true
        changed(final: true, animated: true)
    }

    /// The colors a new space gets, back again: following the Mac, one color, solid and smooth.
    func useDefaultColors() {
        let fresh = draft.withDefaultColors(defaultColor)
        original = fresh
        draft = fresh
        if fresh.brightness == nil { draft.brightness = Self.startingDepth(fresh, dark: isDark) }
        colorChosen = false
        selected = 0
        changed(final: true, animated: true)
    }

    #if DEBUG
    func debugKnobs() -> [CGPoint] {
        let custom = customSwatch.convert(NSPoint(x: customSwatch.bounds.midX, y: customSwatch.bounds.midY), to: nil)
        return [custom] + (wheel.isHidden ? [] : wheel.debugKnobs().map { wheel.convert($0, to: nil) })
    }
    func debugToggleEffects() {
        showsEffects.toggle()
        sync(animated: true)
        onResize?()
    }
    func debugToggleSecondColor() { toggleSecondColor() }
    func debugClickCustom() { customSwatch.onClick?(NSEvent()) }
    /// Presses a knob's center and drags it to that spot, as the mouse would.
    func debugDrag(_ index: Int, to spot: ColorWheel.Spot) {
        guard index < wheel.spots.count else { return }
        var grab = wheel.press(at: wheel.point(wheel.spots[index]))
        let target = wheel.point(spot)
        wheel.drag(&grab, to: target)
        wheel.release(grab, at: target)
    }
    #endif

    /// Custom: the wheel and Shade, shown or folded away.
    func toggleCustom() {
        showsCustom.toggle()
        sync(animated: true)
        onResize?()
    }

    /// The Custom swatch: always shows the wheel and Shade, never folds them.
    func showCustom() {
        guard !showsCustom else { return }
        toggleCustom()
    }

    private func changed(final: Bool, animated: Bool) {
        if final { onCommit?(look) } else { onPreview?(look) }
        sync(animated: animated)
    }

    // MARK: Showing it

    /// Every control from the draft.
    private func sync(animated: Bool) {
        let space = draft
        if space.hue2 == nil { selected = 0 }
        var spots = [ColorWheel.Spot(hue: space.baseHue, amount: min(space.tintAmount, 1))]
        var depths = [depth(0)]
        if let hue2 = space.hue2 {
            spots.append(ColorWheel.Spot(hue: hue2, amount: min(space.tintAmount2, 1)))
            depths.append(depth(1))
        }
        wheel.show(spots, depths: depths, selected: selected, animated: animated)
        let shown = look
        defaultSwatch.isSelected = shown.hasDefaultColors(defaultColor)
        for swatch in swatches { swatch.isSelected = !defaultSwatch.isSelected && swatch.look?.matches(shown) == true }
        customSwatch.isSelected = !defaultSwatch.isSelected && !swatches.contains { $0.isSelected }
        fade([wheel, shadeLabel, shadeSlider], in: showsCustom, animated: animated)
        let colors = [shown.background] + (shown.background2.map { [$0] } ?? [])
        let spot = spots[selected]
        shadeSlider.value = depth(selected)
        shadeSlider.colors = stride(from: 0.0, through: 1, by: 0.2).map { SpaceColor.paint(hue: spot.hue, depth: $0, tint: spot.amount) }
        clearSlider.value = space.seeThrough
        clearSlider.colors = colors
        // What you chose, even while battery saving shows frosted for now.
        glassSwitch.selectedIndex = space.clearGlass != false ? 0 : 1
        grainSlider.value = space.grain ?? 0
        grainSlider.colors = colors
        dial.angle = space.gradientAngle
        let two = space.hue2 != nil
        chips[0].color = colors[0]
        chips[1].color = colors.last ?? colors[0]
        for (i, chip) in chips.enumerated() { chip.isSelected = two && i == selected }
        chips[1].isHidden = !two
        addSlot.isHidden = two
        dial.colors = (colors[0], colors.last ?? colors[0])
        effects.isOpen = showsEffects
        for view in [colorsLabel, chips[0], clearLabel, clearSlider, grainLabel, grainSlider] as [NSView] { view.isHidden = !showsEffects }
        // Frosted or clear only matters once the space is see-through.
        let glassShown = showsEffects && space.isSeeThrough && SpaceInfo.hasClearGlass
        for view in [glassLabel, glassSwitch] as [NSView] { view.isHidden = !glassShown }
        let note = glassShown ? Self.glassNote(clearChosen: space.clearGlass != false, onBattery: PowerSaving.onBattery,
                                               lowPowerMode: PowerSaving.lowPowerMode) : nil
        glassNote.stringValue = note ?? ""
        glassNote.isHidden = note == nil
        let noteChanged = note != glassNoteText
        glassNoteText = note
        if glassShown != showsGlass || noteChanged { showsGlass = glassShown; onResize?() }
        if !showsEffects { chips[1].isHidden = true; addSlot.isHidden = true }
        fade([dial], in: two && showsEffects, animated: animated)
        needsLayout = true
    }

    /// Fades views in or out: the direction dial beside the two colors, the wheel and Shade under Custom.
    private func fade(_ views: [NSView], in show: Bool, animated: Bool) {
        let target: CGFloat = show ? 1 : 0
        let changing = views.filter { $0.isHidden == show || $0.alphaValue != target }
        guard !changing.isEmpty else { return }
        changing.forEach { $0.isHidden = false }
        guard animated, !Tokens.Motion.reduceMotion else {
            changing.forEach { $0.alphaValue = target; $0.isHidden = !show }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.state
            context.timingFunction = Tokens.Motion.easeOut
            changing.forEach { $0.animator().alphaValue = target }
        } completionHandler: {
            MainActor.assumeIsolated {
                // Unless shown again meanwhile.
                for view in changing where view.alphaValue == 0 { view.isHidden = true }
            }
        }
    }

    // MARK: Layout

    private let swatchSize = SwatchRing.side
    private let chipSize: CGFloat = 26
    private let sliderHeight: CGFloat = 30
    /// The Colors row: as tall as the dial, a little more than a slider.
    private let dialSize: CGFloat = 40
    private let disclosureHeight: CGFloat = 28
    /// How tall the wheel is.
    var wheelHeight: CGFloat = ColorWheel.fullHeight { didSet { needsLayout = true } }
    var showsWheel: Bool { showsCustom }

    /// Swatches in each row of the grid: Default, the presets, picture and Custom come out to whole rows of seven.
    static let columns = 7
    /// How many swatches the grid has.
    static var tileCount: Int { 1 + SpaceLook.presets.count + 2 }
    private var swatchRows: Int { (tiles.count + Self.columns - 1) / Self.columns }
    /// The swatch grid's height.
    private var swatchesHeight: CGFloat { CGFloat(swatchRows) * swatchSize + CGFloat(swatchRows - 1) * Tokens.Space.x2 }

    var preferredHeight: CGFloat {
        var h = swatchesHeight + Tokens.Space.x1 + disclosureHeight
        if showsCustom { h += customHeight }
        if showsEffects { h += Tokens.Space.x2 + dialSize + Tokens.Space.x3 + (sliderHeight + Tokens.Space.x3) * 2 - Tokens.Space.x3 }
        if showsGlass { h += sliderHeight + Tokens.Space.x3 }
        if glassNoteText != nil { h += glassNoteHeight + Tokens.Space.x1 }
        return h
    }

    /// The note under Glass, wrapped to the controls' column.
    private var glassNoteHeight: CGFloat {
        let width = (bounds.width > 0 ? bounds.width : SpaceEditorPanel.width - Tokens.Space.x3 * 2) - labelWidth + Label.inset * 2
        return ceil(glassNote.sizeThatFits(NSSize(width: width, height: 200)).height)
    }

    /// Wide enough for the longest name, so every control starts at the same line.
    var labelWidth: CGFloat {
        let widest = [colorsLabel, shadeLabel, clearLabel, glassLabel, grainLabel].map { ceil($0.intrinsicContentSize.width) }.max() ?? 0
        return max(72, widest + Tokens.Space.x3)
    }

    /// Height under the folded Effects label, counted in the panel's margin.
    var trailingAir: CGFloat { showsEffects ? 0 : floor((disclosureHeight - effects.capHeight) / 2) }

    /// The wheel and Shade under the swatches.
    private var customHeight: CGFloat { Tokens.Space.x3 + wheelHeight + Tokens.Space.x3 + sliderHeight }

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        let tiles = self.tiles
        let columns = CGFloat(Self.columns)
        let gap = (width - columns * swatchSize) / (columns - 1)
        for (i, tile) in tiles.enumerated() {
            let column = CGFloat(i % Self.columns), row = CGFloat(i / Self.columns)
            tile.frame = NSRect(x: round(column * (swatchSize + gap)), y: y + row * (swatchSize + Tokens.Space.x2), width: swatchSize, height: swatchSize)
        }
        y += swatchesHeight
        // Laid out while folded too, so they fade in place.
        wheel.frame = NSRect(x: 0, y: y + Tokens.Space.x3, width: width, height: wheelHeight)
        row(shadeLabel, shadeSlider, y: wheel.frame.maxY + Tokens.Space.x3, height: sliderHeight)
        if showsCustom { y += customHeight }
        y += Tokens.Space.x1
        effects.frame = NSRect(x: 0, y: y, width: width, height: disclosureHeight)
        y += disclosureHeight + Tokens.Space.x2
        // Colors: the space's own, then the slot for a second or, with two, which way they run.
        let lh = ceil(colorsLabel.intrinsicContentSize.height)
        colorsLabel.frame = NSRect(x: 0, y: y + colorsLabel.centeredY(in: dialSize), width: labelWidth, height: lh)
        var x = labelWidth
        let chipY = y + (dialSize - chipSize) / 2
        chips[0].frame = NSRect(x: x, y: chipY, width: chipSize, height: chipSize)
        x += chipSize + Tokens.Space.x2
        chips[1].frame = NSRect(x: x, y: chipY, width: chipSize, height: chipSize)
        addSlot.frame = chips[1].frame
        x += chipSize + Tokens.Space.x3
        dial.frame = NSRect(x: x, y: y, width: dialSize, height: dialSize)
        y += dialSize + Tokens.Space.x3
        row(clearLabel, clearSlider, y: y, height: sliderHeight)
        y += sliderHeight + Tokens.Space.x3
        if showsGlass {
            row(glassLabel, glassSwitch, y: y, height: sliderHeight)
            y += sliderHeight + Tokens.Space.x3
            if glassNoteText != nil {
                // Under the switch, its text on the switch's leading edge.
                let height = glassNoteHeight
                glassNote.frame = NSRect(x: labelWidth - Label.inset, y: y - Tokens.Space.x2, width: width - labelWidth + Label.inset * 2, height: height)
                y += height + Tokens.Space.x1
            }
        }
        row(grainLabel, grainSlider, y: y, height: sliderHeight)
        y += sliderHeight + Tokens.Space.x3
    }

    /// A name on the left and its control beside it, every control starting at the same line.
    private func row(_ label: Label, _ control: NSView, y: CGFloat, height: CGFloat) {
        let lh = ceil(label.intrinsicContentSize.height)
        let x = labelWidth
        label.frame = NSRect(x: 0, y: y + label.centeredY(in: height), width: x, height: lh)
        control.frame = NSRect(x: x, y: y, width: bounds.width - x, height: height)
    }
}

/// Edits one space: its name, and how it looks with `SpaceLookEditor`. Everything shows in the window as you drag,
/// and saves when you let go.
final class SpaceEditorPanel: FloatingPanelView, NSTextFieldDelegate {
    override var replacesExtensionPopup: Bool { true }
    private weak var controller: BrowserWindowController?
    let spaceID: UUID
    /// The name in the app's voice, as the sidebar shows it.
    private let nameField = PlainTextField(font: Tokens.Font.voice(20), placeholder: String(localized: "Name this space", comment: "Placeholder of the name field in the space editor."))
    /// The name sits on a soft field, so it reads as something you can type into.
    private let nameBackground = ColorView(color: Tokens.Color.fieldFill)
    private let editor: SpaceLookEditor
    /// The space's icon, at the start of its name; click it to choose one in place of the colors.
    private let iconButton = IconButton(symbol: "circle.dashed", size: .compact, toolTip: String(localized: "Choose Icon", comment: "Tooltip of the icon button before the space's name, in the space editor."))
    private var iconGrid: IconGrid?
    /// The profile the space uses.
    private let profileLabel = SpaceLookEditor.rowLabel(String(localized: "Profile", comment: "Label in a space's editor, before the choice of the profile the space is on."))
    private let profileButton = DropdownButton()
    private let profileLine = ColorView(color: Tokens.Color.separator)
    /// A profile New Profile made here, still called after the space: it takes the name as you type it.
    private var namedProfile: UUID?
    /// While a question it asked is up (moving the space's tabs to another profile), clicks and keys are that
    /// question's: the editor stays as it is under it.
    private var isAsking = false
    private var monitor: Any?
    static let width: CGFloat = 300

    /// `controller` is the browser window it belongs to; Settings passes nil and hosts it in its own window.
    init(spaceID: UUID, controller: BrowserWindowController?) {
        self.spaceID = spaceID
        self.controller = controller
        let space = Library.shared.space(spaceID) ?? SpaceInfo(name: "", color: .sky)
        let dark = (controller?.window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        editor = SpaceLookEditor(space: space, defaultColor: Library.shared.defaultColor(ofSpace: spaceID) ?? space.color, dark: dark)
        super.init(frame: .zero)
        radius = Tokens.Radius.panel
        nameField.stringValue = space.name
        nameField.delegate = self
        nameBackground.wantsLayer = true
        nameBackground.layer?.cornerCurve = .continuous
        nameBackground.layer?.cornerRadius = Tokens.Radius.row
        [nameBackground, nameField, editor, iconButton, profileLine, profileLabel, profileButton].forEach { addSubview($0) }
        // Explains profiles inline (#201).
        profileLabel.toolTip = ProfileChoice.spaceNote
        profileButton.toolTip = ProfileChoice.spaceNote
        profileButton.setAccessibilityLabel(profileLabel.stringValue)
        refreshProfiles()
        refreshBackground()
        editor.backgroundSwatch.onClick = { [weak self] event in
            guard let self else { return }
            if self.editor.backgroundSwatch.hitsBadge(event) { self.clearBackground() } else { self.pickBackground() }
        }
        editor.backgroundSwatch.onRemove = { [weak self] in self?.clearBackground() }
        profileButton.onSelect = { [weak self] index in self?.chooseProfile(at: index) }
        profileButton.actions = [DropdownButton.Action(title: ProfileChoice.newForSpace, symbol: "plus") { [weak self] in
            self?.newProfile()
        }]
        refreshIconButton(space.icon)
        iconButton.onClick = { [weak self] _ in self?.toggleIcons() }
        editor.onPreview = { [weak self] look in
            guard let self else { return }
            (self.controller ?? BrowserWindowController.undoTarget)?.previewSpace(look)
        }
        editor.onCommit = { [weak self] look in
            guard let self else { return }
            Library.shared.setLook(look)
            self.edited = true
        }
        editor.onResize = { [weak self] in
            self?.layoutContent()
            self?.resizeToFit()
        }
        onLayout = { [weak self] in self?.layoutContent() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    /// A panel's padding, and its name a row tall.
    private let pad = Tokens.Space.x3
    private let nameHeight = Tokens.Metric.rowHeight

    /// The line over Profile and the row itself, with the space around the line.
    private var profileRowHeight: CGFloat { Tokens.Space.x3 + Tokens.Metric.hairline + Tokens.Space.x3 + Tokens.Page.controlHeight }

    var contentHeight: CGFloat {
        pad + nameHeight + Tokens.Space.x3 + (iconGrid != nil ? IconGrid.height : editor.preferredHeight - editor.trailingAir) + profileRowHeight + pad
    }

    private func refreshIconButton(_ icon: String?) {
        iconButton.glyph = icon.map { IconChoice.image($0, size: Tokens.Symbol.compactGlyph) }
        iconButton.isSelected = iconGrid != nil
    }

    /// The icons take the colors' place, and the button again (or picking one) brings the colors back.
    private func toggleIcons() {
        if let grid = iconGrid {
            grid.removeFromSuperview()
            iconGrid = nil
            editor.isHidden = false
        } else {
            let grid = IconGrid(noneSymbol: "circle.dashed", selected: Library.shared.space(spaceID)?.icon)
            grid.onPick = { [weak self] icon in
                guard let self else { return }
                Library.shared.setIcon(icon, forSpace: self.spaceID)
                self.edited = true
                self.refreshIconButton(icon)
                // An emoji is typed one at a time; a symbol is one click and done.
                if icon.map(IconChoice.isSymbol) != false { self.toggleIcons() }
            }
            addSubview(grid)
            iconGrid = grid
            editor.isHidden = true
        }
        refreshIconButton(Library.shared.space(spaceID)?.icon)
        layoutContent()
        resizeToFit()
    }

    /// The panel grows or shrinks between the colors and the icons, keeping the edge nearest what opened it.
    private func resizeToFit() {
        guard let superview else { return }
        if controller != nil { fitWheel(in: superview.bounds.height) }
        guard abs(frame.height - contentHeight) > 0.5 else { return }
        var target = frame
        let delta = contentHeight - frame.height
        target.size.height = contentHeight
        if superview.isFlipped, anchoredBelow == false { target.origin.y -= delta }
        if controller != nil { target.origin.y = Self.clampedTop(target.origin.y, height: contentHeight, in: superview.bounds.height) }
        target.origin.y = max(Tokens.Space.x2, target.origin.y)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Tokens.Motion.reduceMotion ? 0 : Tokens.Motion.standard
            context.timingFunction = Tokens.Motion.drawer
            context.allowsImplicitAnimation = true
            animator().frame = target
            layoutSubtreeIfNeeded()
        }
    }

    /// True when it hangs down from what opened it; false when it rises from the dots at the bottom.
    private var anchoredBelow = false

    /// Room left above and below the panel in the window.
    static let topMargin = Tokens.Space.x2, bottomMargin = Tokens.Space.x4

    /// Whether it rises from what opened it (in the window's lower half) rather than hanging from it.
    static func rises(from anchor: NSRect, in height: CGFloat) -> Bool { anchor.midY > height / 2 }

    /// Its top, moved so the whole panel stays in the window; the top wins when it can't fit at all.
    static func clampedTop(_ top: CGFloat, height: CGFloat, in windowHeight: CGFloat) -> CGFloat {
        max(topMargin, min(top, windowHeight - height - bottomMargin))
    }

    /// The wheel's height, smaller in a short window so everything fits.
    static func wheelHeight(overflow: CGFloat) -> CGFloat {
        min(ColorWheel.fullHeight, max(ColorWheel.minimumHeight, ColorWheel.fullHeight - max(0, overflow)))
    }

    private func fitWheel(in windowHeight: CGFloat) {
        let full = contentHeight + (editor.showsWheel ? ColorWheel.fullHeight - editor.wheelHeight : 0)
        let height = Self.wheelHeight(overflow: full - (windowHeight - Self.topMargin - Self.bottomMargin))
        if editor.wheelHeight != height {
            editor.wheelHeight = height
            layoutContent()
        }
    }

    private func layoutContent() {
        let width = bounds.width - pad * 2
        let fh = ceil(nameField.intrinsicContentSize.height)
        nameBackground.frame = NSRect(x: pad, y: pad, width: width, height: nameHeight)
        let ib = iconButton.frame.width
        iconButton.frame.origin = NSPoint(x: pad + (nameHeight - ib) / 2, y: pad + (nameHeight - ib) / 2)
        let textX = pad + nameHeight
        nameField.frame = NSRect(x: textX, y: pad + (nameHeight - fh) / 2, width: pad + width - textX - Tokens.Space.x2, height: fh)
        let below = pad + nameHeight + Tokens.Space.x3
        editor.frame = NSRect(x: pad, y: below, width: width, height: editor.preferredHeight)
        iconGrid?.frame = NSRect(x: pad, y: below, width: width, height: IconGrid.height)
        let lineY = below + (iconGrid != nil ? IconGrid.height : editor.preferredHeight - editor.trailingAir) + Tokens.Space.x3
        profileLine.frame = NSRect(x: pad, y: lineY, width: width, height: Tokens.Metric.hairline)
        let rowY = lineY + Tokens.Metric.hairline + Tokens.Space.x3, rowH = Tokens.Page.controlHeight
        let labelWidth = profileLabel.textWidth
        profileLabel.frame = NSRect(x: pad, y: rowY + profileLabel.centeredY(in: rowH), width: labelWidth, height: profileLabel.lineHeight)
        let menuWidth = min(profileButton.intrinsicContentSize.width, width - labelWidth)
        profileButton.frame = NSRect(x: pad + width - menuWidth, y: rowY, width: menuWidth, height: rowH)
    }

    func show(from anchor: NSView? = nil) {
        guard let controller else { return }
        let overlay = controller.root.overlay
        // Beside the sidebar, over the page: right of it, or left of it on the right.
        let beside = controller.root.besideSidebar(width: Self.width)
        let x = min(max(Tokens.Space.x2, beside), overlay.bounds.width - Self.width - Tokens.Space.x2)
        // What opened it, or the space's name when nothing on screen did (the menu bar, the command bar).
        var source = anchor?.window != nil ? anchor : nil
        if source == nil, let header = controller.sidebar.list.headerView, header.window != nil { source = header }
        let place = source.map { $0.convert($0.bounds, to: overlay) }
        // Low in the window (a space dot, the +) it rises from there; higher up it hangs from it.
        let rises = place.map { Self.rises(from: $0, in: overlay.bounds.height) } ?? false
        anchoredBelow = !rises
        fitWheel(in: overlay.bounds.height)
        let height = contentHeight
        var top: CGFloat
        if let place {
            top = rises ? place.maxY - height : place.minY - Tokens.Space.x2
        } else {
            top = controller.root.cardFrame.minY + Tokens.Space.x2
        }
        top = Self.clampedTop(top, height: height, in: overlay.bounds.height)
        frame = NSRect(x: x, y: top, width: Self.width, height: height)
        overlay.addSubview(self)
        // Out of the sidebar's side of it: the left, or the right beside a sidebar on the right.
        let right = controller.root.sidebarOnRight
        growsFrom = rises ? CGPoint(x: right ? 0.9 : 0.1, y: 1) : CGPoint(x: right ? 1 : 0, y: 0.1)
        present(arrival: .pop)
        controller.window?.makeFirstResponder(nameField)
        // The cursor at the end, not the whole name selected: you came to change the color as often as the name. A
        // name Zigzag made up ("Space 2") is selected instead, so typing replaces it.
        if let editor = nameField.currentEditor() {
            let name = nameField.stringValue
            let placeholder = name.range(of: #"^Space \d+$"#, options: .regularExpression) != nil
                || (1...99).contains { name == String(localized: "Space \($0)", comment: "A new space's made-up name, like “Space 2”.") }
            editor.selectedRange = placeholder ? NSRange(location: 0, length: nameField.stringValue.utf16.count)
                                               : NSRange(location: nameField.stringValue.utf16.count, length: 0)
        }
        controller.root.holdReveal = true
        startMonitoring()
    }

    /// In Settings: dropping from the Edit button that opened it, its right edge on the button's, inside that window.
    func show(in host: NSView, below anchor: NSView) {
        let button = anchor.convert(anchor.bounds, to: host)
        let height = contentHeight
        let below = host.isFlipped ? button.maxY + Tokens.Space.x1 : button.minY - Tokens.Space.x1 - height
        let fits = host.isFlipped ? below + height <= host.bounds.height - Tokens.Space.x2 : below >= Tokens.Space.x2
        // Not enough room underneath: it opens upward from the button instead.
        let above = host.isFlipped ? button.minY - Tokens.Space.x1 - height : button.maxY + Tokens.Space.x1
        // Never past the window's edges: if neither way fits, it slides to fit and sits left of the button.
        let y = max(Tokens.Space.x2, min(fits ? below : above, host.bounds.height - height - Tokens.Space.x2))
        let x = max(Tokens.Space.x2, min(button.maxX - Self.width, host.bounds.width - Self.width - Tokens.Space.x2))
        frame = NSRect(x: x, y: y, width: Self.width, height: height)
        anchoredBelow = fits
        host.addSubview(self)
        present(arrival: .instant)
        window?.makeFirstResponder(nameField)
        if let editor = nameField.currentEditor() { editor.selectedRange = NSRange(location: nameField.stringValue.count, length: 0) }
        startMonitoring()
    }

    var onClose: (() -> Void)?

    private func startMonitoring() {
        monitor = TouchPress.addMonitor(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            // The Profile menu, and a question asked from it, sit outside the panel: a click or key there is theirs.
            if MenuPanel.current != nil || self.isAsking { return event }
            if event.type == .keyDown {
                // Esc in another window (Settings, a second browser window) is that window's; mid-word in a
                // Chinese or Japanese input method, it belongs to the input method.
                if event.keyCode == 53, event.window === self.window,
                   (self.window?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                    // A search for an emoji goes first (#163).
                    if self.iconGrid?.endSearch() != true { self.cancel() }
                    return nil
                }
                return event
            }
            if event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close() }
            return event
        }
    }

    // MARK: Profile

    /// The profiles as the menu lists them.
    private var profileIDs: [UUID] = []

    private func refreshProfiles() {
        profileIDs = ProfileChoice.fill(profileButton, selected: Library.shared.profileID(ofSpace: spaceID))
        needsLayout = true
    }

    /// Where a question is asked from here: over the whole window, the editor under it.
    private var sheetHost: NSView? { (controller?.window ?? window)?.contentView }

    private func chooseProfile(at index: Int) {
        let library = Library.shared
        guard profileIDs.indices.contains(index), let profile = library.directory.profile(profileIDs[index]) else { return }
        guard profile.id != library.profileID(ofSpace: spaceID) else { return }
        confirmMove(to: profile.displayName, cancelled: { [weak self] in self?.refreshProfiles() }) { [weak self] in self?.move(to: profile.id) }
    }

    /// Whether the space has pages loaded, which another profile rebuilds.
    private var hasOpenPages: Bool {
        WindowManager.shared.everyOpenTab.contains { $0.spaceID == spaceID && !$0.isPrivate && $0.webView != nil }
    }

    /// Pages that are loaded are rebuilt in the other profile, which is worth a question; a space with none open
    /// (a new one) just changes.
    private func confirmMove(to profileName: String, cancelled: @escaping () -> Void, then move: @escaping () -> Void) {
        guard hasOpenPages, let host = sheetHost, let space = Library.shared.space(spaceID) else { move(); return }
        isAsking = true
        ConfirmSheet.show(in: host, title: String(localized: "Move \(space.name) to \(profileName)?", comment: "Title of the sheet that asks before a space with open tabs is put on another profile. First the space's name, then the profile's."),
                          message: String(localized: "Its open tabs reload in \(profileName), with that profile’s sign-ins and extensions. Pages you were filling in may lose what you typed.", comment: "Message of the sheet that asks before a space with open tabs is put on another profile. The placeholder is the profile's name."),
                          confirmTitle: String(localized: "Move", comment: "Button of the sheet that asks before a space is put on another profile.")) { [weak self] confirmed in
            self?.isAsking = false
            if confirmed { move() } else { cancelled() }
        }
    }

    private func move(to profile: UUID) {
        Library.shared.setProfile(profile, forSpace: spaceID)
        if profile != namedProfile { namedProfile = nil }
        edited = true
        refreshProfiles()
    }

    /// New Profile: one of the space's own, named after it, in one step. No sheet: its name and color can be
    /// changed later in Settings › Profiles, and while the space is still being named here, it follows the name.
    private func newProfile() {
        commitName()
        let library = Library.shared
        guard let space = library.space(spaceID) else { return }
        let name = ProfileDirectory.freshName(space.name, taken: library.profiles.map(\.displayName))
        confirmMove(to: name, cancelled: { [weak self] in self?.refreshProfiles() }) { [weak self] in
            guard let self, let made = Library.shared.addProfile(forSpace: self.spaceID) else { return }
            self.namedProfile = made.id
            self.edited = true
            self.refreshProfiles()
        }
    }

    // MARK: Background

    /// Shows the picture while the space still has one.
    private func refreshBackground() {
        let name = Library.shared.space(spaceID)?.backgroundImage.flatMap { SpaceBackground.isKept($0) ? $0 : nil }
        editor.backgroundSwatch.image = name.flatMap { SpaceBackground.thumbnail($0, side: 96) }
    }

    /// Any picture, copied into Zigzag's folder at screen size.
    private func pickBackground() {
        guard let host = controller?.window ?? window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button of the panel that picks a picture for a space's empty page.")
        panel.message = String(localized: "Choose a picture for this space’s empty page.", comment: "Message of the panel that picks a picture for a space's empty page, from Background in the space's editor.")
        isAsking = true
        let id = spaceID
        panel.beginSheetModal(for: host) { [weak self] response in
            self?.isAsking = false
            guard response == .OK, let url = panel.url else { return }
            let screen = SpaceBackground.screenPixels
            DispatchQueue.global(qos: .userInitiated).async {
                let name = SpaceBackground.store(url, for: id, screen: screen)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let name else {
                            if let host = self?.sheetHost {
                                ConfirmSheet.notice(in: host, title: String(localized: "Couldn’t use this picture", comment: "Title of the notice when a picture chosen for a space's empty page can't be read."),
                                                    message: String(localized: "Zigzag can’t read that file as a picture. Choose a photo or an image file, like a JPEG, PNG or HEIC.", comment: "Message of the notice when a picture chosen for a space's empty page can't be read."))
                            }
                            return
                        }
                        Library.shared.setBackgroundImage(name, forSpace: id)
                        self?.edited = true
                        self?.refreshBackground()
                    }
                }
            }
        }
    }

    /// Remove: back to the default wash and delete Zigzag's copy.
    private func clearBackground() {
        Library.shared.setBackgroundImage(nil, forSpace: spaceID)
        edited = true
        refreshBackground()
    }

    #if DEBUG
    /// Debug bridge: the Background swatch with a file already picked.
    func debugSetBackground(_ url: URL) {
        guard let name = SpaceBackground.store(url, for: spaceID, screen: SpaceBackground.screenPixels) else { return }
        Library.shared.setBackgroundImage(name, forSpace: spaceID)
        edited = true
        refreshBackground()
    }
    func debugRemoveBackground() { clearBackground() }
    func debugToggleCustom() { editor.toggleCustom() }
    func debugClickCustom() { editor.debugClickCustom() }
    func debugToggleEffects() { editor.debugToggleEffects() }
    func debugToggleSecondColor() { editor.debugToggleSecondColor() }
    func debugDrag(_ index: Int, to spot: ColorWheel.Spot) { editor.debugDrag(index, to: spot) }
    /// For the debug bridge: what a press on the name, the Custom swatch and each knob lands on, and where the panel is
    /// (window points, top left).
    func debugProbe() -> String {
        guard let window, let frame = window.contentView?.superview else { return "no window" }
        let height = window.frame.height
        let name = nameField.convert(NSPoint(x: nameField.bounds.midX, y: nameField.bounds.midY), to: nil)
        let knobs = ([name] + editor.debugKnobs()).map { p -> String in
            let hit = frame.hitTest(frame.convert(p, from: nil))
            return "(\(Int(p.x)),\(Int(height - p.y)))=\(hit.map { "\(type(of: $0))" } ?? "nil")"
        }
        let f = convert(bounds, to: nil)
        return "panel x=\(Int(f.minX)) top=\(Int(height - f.maxY)) bottom=\(Int(height - f.minY)) window=\(Int(height)) " + knobs.joined(separator: " ")
    }
    #endif

    /// A profile created with the space (Settings › Spaces › Give new spaces their own profile, #291); takes the space name
    /// as you type, like New Profile here.
    func follow(madeProfile id: UUID) {
        namedProfile = id
        refreshProfiles()
    }

    /// The space as it was when the editor opened; closing registers one ⌘Z for everything changed.
    private let before = Library.shared.snapshot
    private var edited = false

    /// Set for a space just made with +: Esc takes the space away again instead of keeping it.
    var onCancel: (() -> Void)?
    private var cancelled = false

    /// Esc: closes, and a space just made goes away again, unless you've already named it or picked its look: that
    /// work is kept, as Return or a click outside keeps it.
    func cancel() {
        guard let onCancel, !edited else { close(); return }
        cancelled = true
        close()
        onCancel()
    }

    func close() {
        if let monitor { TouchPress.removeMonitor(monitor) }
        monitor = nil
        if !cancelled { commitName() }
        if edited, !cancelled { (controller ?? BrowserWindowController.undoTarget)?.recordLibraryUndo(String(localized: "Edit Space", comment: "Undo action name, shown in Edit › Undo."), before: before) }
        if let controller {
            controller.root.holdReveal = false
            dismiss()
            if let webView = controller.selectedWebView { controller.window?.makeFirstResponder(webView) }
        } else {
            window?.makeFirstResponder(nil)
            dismiss(instantly: true)
        }
        if SpaceEditorPanel.current === self { SpaceEditorPanel.current = nil }
        onClose?()
    }

    private func commitName() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != Library.shared.space(spaceID)?.name {
            Library.shared.renameSpace(spaceID, to: name)
            edited = true
            if let namedProfile {
                Library.shared.renameProfile(namedProfile, after: name)
                refreshProfiles()
            }
        }
    }

    /// Use Default Colors, like its swatch (debug bridge).
    func useDefaultColors() { editor.useDefaultColors() }

    #if DEBUG
    /// For the debug bridge: New Profile in the Profile menu, and a name typed into the field.
    func debugNewProfile() { newProfile() }
    func debugType(_ name: String) {
        nameField.stringValue = name
        commitName()
    }
    #endif

    func controlTextDidChange(_ obj: Notification) { commitName() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            close()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    static weak var current: SpaceEditorPanel?

    static func toggle(spaceID: UUID, anchor: NSView? = nil, in controller: BrowserWindowController) {
        if let current {
            let same = current.spaceID == spaceID
            current.close()
            if same { return }
        }
        controller.closeFloatingPanels()
        let panel = SpaceEditorPanel(spaceID: spaceID, controller: controller)
        current = panel
        panel.show(from: anchor)
    }
}

#if DEBUG
import AppKit
import CoreImage

/// Debug builds: the tactile kit (Materials.swift) put together as onboarding's first screen could be, in a window
/// of its own. DebugBridge's `materials` opens it.
final class MaterialsShowcase: NSWindowController, NSWindowDelegate {
    static var shared: MaterialsShowcase?
    let hero = MaterialsHero()

    static func show() {
        let isNew = shared == nil
        if isNew { shared = MaterialsShowcase() }
        shared?.window?.makeKeyAndOrderFront(nil)
        if isNew, let hero = shared?.hero { shared?.window?.makeFirstResponder(hero) }
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Materials"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = hero
        window.initialFirstResponder = hero
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }

    /// `materials [light|dark|system]`, `materials id <path>` (the window number), `materials point <x> <y>` (where
    /// the pointer is, -1...1), `materials state <primary|link|deck|mark> <rest|hover|press>`, `materials next` (the
    /// next space in front), `materials fps` (five seconds of pointer moves, timed, to debug.log), `materials close`.
    static func debug(_ arg: String) {
        let words = arg.split(separator: " ").map(String.init)
        if words.first == "close" { shared?.close(); return }
        show()
        guard let shared, let window = shared.window else { return }
        switch words.first ?? "" {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "system": window.appearance = nil
        case "id":
            if words.count > 1 { try? "\(window.windowNumber)".write(toFile: words[1], atomically: true, encoding: .utf8) }
        case "point":
            let n = words.dropFirst().compactMap { Double($0) }
            if n.count == 2 { shared.hero.point(at: CGPoint(x: n[0], y: n[1])) }
        case "state":
            if words.count == 3 { shared.hero.debugState(words[1], words[2]) }
        case "next": shared.hero.deck.advance()
        case "front": shared.hero.deck.hold(Int(words.dropFirst().first ?? "0") ?? 0)
        case "fps": shared.hero.measure()
        default: break
        }
    }
}

/// Onboarding's first screen: what Zigzag is, beside a deck of glass sheets, one per space, the front one carrying a
/// sidebar. The deck turns toward the pointer and fans open under it; every few seconds the next space comes to the
/// front and the sky leans toward its color.
final class MaterialsHero: NSView {
    private let sky = SkyBackdrop()
    let deck = SpaceDeck()
    private let wordmark = EmbossedWordmark()
    private let headline = Label("Your tabs, in calm spaces", font: .systemFont(ofSize: Tokens.Material.headline, weight: .semibold), color: Tokens.Color.textPrimary)
    private let line: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "Work, home and everything else, each in a space of its own color. Your sites wait in each one.")
        field.font = .systemFont(ofSize: Tokens.Material.largeText)
        field.textColor = Tokens.Color.textSecondary
        field.isSelectable = false
        return field
    }()
    let primary = TactileButton(title: "Get Started", style: .primary, size: .large)
    let link = TactileButton(title: "Import from Chrome", style: .link, size: .large)
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        [sky, deck, wordmark, headline, line, primary, link].forEach { addSubview($0) }
        primary.onClick = { _ in }
        link.onClick = { _ in }
        deck.frontChanged = { [weak self] color in self?.sky.tint = color }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private static let margin: CGFloat = 96
    private static let column: CGFloat = 392
    private static let markHeight: CGFloat = 40

    override func layout() {
        super.layout()
        sky.frame = bounds
        // The deck owns the right of the window, reaching a little under the text column so the two read as one.
        deck.frame = NSRect(x: bounds.width * 0.42, y: 0, width: bounds.width * 0.58, height: bounds.height)
        let x = Self.margin
        let headlineHeight = headline.lineHeight
        let lineHeight = ceil(line.sizeThatFits(NSSize(width: Self.column, height: 200)).height)
        let h = Tokens.Material.largeControlHeight
        let total = Self.markHeight + Tokens.Space.x8 + headlineHeight + Tokens.Space.x3 + lineHeight + Tokens.Space.x8 + h + Tokens.Space.x3 + h
        var y = round((bounds.height + total) / 2) - 8
        y -= Self.markHeight
        let markWidth = Self.markHeight * WordmarkView.aspect
        wordmark.frame = NSRect(x: x - 1, y: y, width: markWidth, height: Self.markHeight)
        y -= Tokens.Space.x8 + headlineHeight
        headline.frame = NSRect(x: x - Label.inset, y: y, width: Self.column, height: headlineHeight)
        y -= Tokens.Space.x3 + lineHeight
        line.frame = NSRect(x: x - Label.inset, y: y, width: Self.column, height: lineHeight)
        y -= Tokens.Space.x8 + h
        let buttonWidth: CGFloat = 196
        primary.frame = NSRect(x: x, y: y, width: buttonWidth, height: h)
        y -= Tokens.Space.x3 + h
        link.frame = NSRect(x: x, y: y, width: buttonWidth, height: h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pointer(atViewPoint: p)
    }

    override func mouseExited(with event: NSEvent) {
        point(at: .zero)
        deck.isOpen = false
        wordmark.glints = false
    }

    private func pointer(atViewPoint p: CGPoint) {
        point(at: CGPoint(x: (p.x - bounds.midX) / (bounds.width / 2), y: (p.y - bounds.midY) / (bounds.height / 2)))
        deck.isOpen = deck.contains(convert(p, to: deck))
        wordmark.glints = wordmark.frame.insetBy(dx: -12, dy: -12).contains(p)
    }

    /// Everything turns toward and is lit from the pointer, x and y in -1...1 from the middle.
    func point(at raw: CGPoint) {
        let p = CGPoint(x: max(-1, min(1, raw.x)), y: max(-1, min(1, raw.y)))
        deck.setTilt(p)
        // The glint is measured from the wordmark, which sits up and to the left.
        wordmark.light = CGPoint(x: (p.x + 0.55) * 1.6, y: p.y - 0.3)
    }

    /// Return is Get Started.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            primary.onClick?(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func debugState(_ name: String, _ state: String) {
        switch name {
        case "primary", "link":
            let button = name == "primary" ? primary : link
            button.isHovered = state == "hover" || state == "press"
            button.isPressed = state == "press"
        case "deck": deck.isOpen = state != "rest"
        case "mark": wordmark.glints = state != "rest"
        default: break
        }
    }

    // MARK: Timing (debug)

    private var meter: (link: CADisplayLink, start: CFTimeInterval, last: CFTimeInterval, frames: [Double], work: [Double], opened: Int)?

    /// Five seconds of the pointer circling the window (through the deck and out), with every frame's interval and
    /// the main thread's own work timed, written to debug.log.
    func measure() {
        meter?.link.invalidate()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        let now = CACurrentMediaTime()
        meter = (link, now, now, [], [], 0)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard var m = meter else { return }
        let now = CACurrentMediaTime()
        let t = now - m.start
        if t > 0.05 { m.frames.append((now - m.last) * 1000) }
        m.last = now
        let angle = t / 2.5 * 2 * .pi
        let p = CGPoint(x: bounds.midX + cos(angle) * bounds.width * 0.4, y: bounds.midY + sin(angle) * bounds.height * 0.38)
        let wasOpen = deck.isOpen
        let begin = CACurrentMediaTime()
        pointer(atViewPoint: p)
        m.work.append((CACurrentMediaTime() - begin) * 1000)
        if deck.isOpen != wasOpen { m.opened += 1 }
        meter = m
        guard t >= 5 else { return }
        link.invalidate()
        meter = nil
        let sorted = m.frames.sorted()
        let average = sorted.reduce(0, +) / Double(max(1, sorted.count))
        let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        let slow = sorted.filter { $0 > 1.5 * (sorted.first ?? 16) + 4 }.count
        let work = m.work.sorted()
        debugLog(String(format: "materials fps: %d frames in 5s, %.1f fps, frame avg %.2f ms p95 %.2f ms max %.2f ms, %d long; main-thread work avg %.3f ms max %.3f ms; deck opened/closed %d times",
                        sorted.count, Double(sorted.count) / 5, average, p95, sorted.last ?? 0, slow,
                        work.reduce(0, +) / Double(max(1, work.count)), work.last ?? 0, m.opened))
        point(at: .zero)
        deck.isOpen = false
    }
}

// MARK: - The deck of spaces

/// One space as a sheet of tinted glass: frosted (what's behind it blurs through), a tint brighter at the top, a glow
/// inside its edge, a specular rim on top, grain, two shadows, and a sidebar drawn on it as soft shapes.
final class SpaceSheet {
    let root = CALayer()
    private let cast = CastShadow()
    private let frost = CALayer()
    private let body = CAGradientLayer()
    private let glow = InnerShadow()
    private let sheen = CAGradientLayer()
    private let grain = CALayer()
    private let rim = GradientStroke(width: 1)
    private let outline = CAShapeLayer()
    private let sidebar = CALayer()
    private var shapes: [(layer: CAShapeLayer, alpha: CGFloat)] = []
    private var dots: [CAShapeLayer] = []
    static let size = CGSize(width: 284, height: 380)
    static let radius: CGFloat = 32

    init() {
        let rect = CGRect(origin: .zero, size: Self.size)
        root.bounds = rect
        for layer in [frost, body, sheen, grain] {
            layer.frame = rect
            layer.cornerRadius = Self.radius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 22]) { frost.backgroundFilters = [blur] }
        frost.backgroundColor = NSColor.white.withAlphaComponent(0.001).cgColor
        body.startPoint = CGPoint(x: 0.5, y: 1)
        body.endPoint = CGPoint(x: 0.5, y: 0)
        sheen.type = .radial
        grain.backgroundColor = MaterialImages.grain.cgColor
        grain.opacity = Tokens.Material.grainOpacity * 0.5
        let shape = MaterialShape.rounded(rect, radius: Self.radius)
        cast.set(frame: rect, path: MaterialShape.rounded(rect.insetBy(dx: 10, dy: 6), radius: Self.radius))
        glow.set(frame: rect, path: shape)
        rim.set(frame: rect, path: MaterialShape.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: Self.radius - 0.5))
        outline.frame = rect
        outline.path = MaterialShape.rounded(rect.insetBy(dx: -0.25, dy: -0.25), radius: Self.radius + 0.25)
        outline.fillColor = nil
        outline.lineWidth = 0.5
        sidebar.frame = rect
        buildSidebar(in: rect)
        [cast.ambient, cast.contact, frost, body, glow.layer, sidebar, sheen, grain, rim.layer, outline].forEach { root.addSublayer($0) }
    }

    /// The sidebar, abstract: the window's three lights, the address, a strip of favorites, a quiet label, rows (one
    /// chosen, as a soft card), and the space dots at the bottom.
    private func buildSidebar(in rect: CGRect) {
        func add(_ path: CGPath, _ alpha: CGFloat) {
            let layer = CAShapeLayer()
            layer.path = path
            sidebar.addSublayer(layer)
            shapes.append((layer, alpha))
        }
        let pad: CGFloat = 18, w = rect.width, top = rect.height
        for i in 0..<3 { add(CGPath(ellipseIn: CGRect(x: pad + CGFloat(i) * 14, y: top - 26, width: 9, height: 9), transform: nil), 0.32) }
        add(MaterialShape.capsule(CGRect(x: pad - 4, y: top - 66, width: w - (pad - 4) * 2, height: 28)), 0.13)
        let tileWidth = (w - (pad - 4) * 2 - 3 * 8) / 4
        for i in 0..<4 {
            let tile = CGRect(x: pad - 4 + CGFloat(i) * (tileWidth + 8), y: top - 122, width: tileWidth, height: 42)
            add(MaterialShape.rounded(tile, radius: 12), 0.13)
            add(CGPath(ellipseIn: CGRect(x: tile.midX - 7, y: tile.midY - 7, width: 14, height: 14), transform: nil), 0.34)
        }
        add(MaterialShape.capsule(CGRect(x: pad, y: top - 148, width: 44, height: 6)), 0.2)
        let widths: [CGFloat] = [132, 104, 150, 88, 120]
        for (i, width) in widths.enumerated() {
            let y = top - 186 - CGFloat(i) * 36
            if i == 1 { add(MaterialShape.rounded(CGRect(x: pad - 8, y: y - 8, width: w - (pad - 8) * 2, height: 30), radius: 10), 0.16) }
            add(MaterialShape.rounded(CGRect(x: pad, y: y + 1, width: 12, height: 12), radius: 3.5), 0.38)
            add(MaterialShape.capsule(CGRect(x: pad + 22, y: y + 3, width: width, height: 8)), i == 1 ? 0.5 : 0.24)
        }
        for i in 0..<4 {
            let dot = CAShapeLayer()
            dot.path = CGPath(ellipseIn: CGRect(x: w / 2 - 27 + CGFloat(i) * 16 - 3.5, y: 20, width: 7, height: 7), transform: nil)
            sidebar.addSublayer(dot)
            dots.append(dot)
        }
    }

    /// Shows a space: its tint, ink for the sidebar that reads on it, and its dot lit among the four.
    /// Only the front sheet carries the sidebar: seen through the glass, the others' would only smear.
    var showsSidebar = true { didSet { sidebar.isHidden = !showsSidebar } }

    func show(_ space: SpaceDeck.Space, index: Int, isDark: Bool, animated: Bool) {
        let tone = isDark ? space.dark : space.light
        let ink = isDark || space.isDeep ? NSColor.white : Brand.navy
        MaterialMotion.animate(animated ? 0.9 : 0) {
            body.colors = [tone.top.cgColor, tone.bottom.cgColor]
            for shape in shapes { shape.layer.fillColor = ink.withAlphaComponent(shape.alpha * (ink == .white ? 1.1 : 1)).cgColor }
            for (i, dot) in dots.enumerated() { dot.fillColor = ink.withAlphaComponent(i == index ? 0.85 : 0.25).cgColor }
            let m = Tokens.Material.self
            // A thin glow under the edge, not a haze: the tint stays clear.
            glow.set(color: NSColor.white.cgColor, opacity: isDark ? 0.35 : 0.45, radius: 8, drop: 2)
            let top = m.rim.cg(isDark), catchLight = m.rimCatch.cg(isDark)
            rim.set([top, top.copy(alpha: top.alpha * 0.25)!, catchLight.copy(alpha: 0)!, catchLight], at: [0, 0.18, 0.7, 1])
            outline.strokeColor = m.outline.cg(isDark)
            let hot = m.sheen.cg(isDark)
            sheen.colors = [hot, hot.copy(alpha: 0)!]
            sheen.opacity = space.isDeep || isDark ? 0.45 : 0.7
            cast.apply(Tokens.Material.Elevation(ambientRadius: 26, ambientDrop: 18, ambientOpacity: 0.16, contactRadius: 2, contactDrop: 1.5, contactOpacity: 0.16), isDark: isDark)
        }
    }

    /// The hot spot leans toward the light, x and y in -1...1.
    func setLight(_ p: CGPoint) {
        let cx = 0.5 + p.x * 0.45, cy = 1.02 + p.y * 0.08
        sheen.startPoint = CGPoint(x: cx, y: cy)
        sheen.endPoint = CGPoint(x: cx + 0.75, y: cy - 0.5)
    }
}

/// The deck: four spaces as glass sheets fanned in perspective, the front one first. It turns toward the pointer,
/// fans open while the pointer is over it, floats a little, and every few seconds brings the next space forward.
/// Still with Reduce Motion; paused while the window is out of sight.
final class SpaceDeck: NSView {
    struct Tone { let top: NSColor; let bottom: NSColor }
    struct Space { let light: Tone; let dark: Tone; let isDeep: Bool; let sky: NSColor? }

    /// Zigzag's navy, then a soft sky, a warm sand and a mint: the space colors (`SpaceColor`) as glass.
    static let spaces: [Space] = {
        let hex = Tokens.Color.hex
        return [
            Space(light: Tone(top: hex(0x31588A, 0.92), bottom: hex(0x1E3A5F, 0.95)), dark: Tone(top: hex(0x31588A, 0.9), bottom: hex(0x1A3253, 0.94)), isDeep: true, sky: nil),
            Space(light: Tone(top: hex(0xD3E4F7, 0.88), bottom: hex(0x98BCE8, 0.92)), dark: Tone(top: hex(0x4C73A0, 0.88), bottom: hex(0x2F4D70, 0.92)), isDeep: false, sky: hex(0x8DB8E8, 1)),
            Space(light: Tone(top: hex(0xF7EBD6, 0.9), bottom: hex(0xE2C38E, 0.94)), dark: Tone(top: hex(0x86704F, 0.88), bottom: hex(0x5A4A33, 0.92)), isDeep: false, sky: hex(0xE8C79A, 1)),
            Space(light: Tone(top: hex(0xD9F1E8, 0.88), bottom: hex(0x92CFBA, 0.92)), dark: Tone(top: hex(0x3F7A6B, 0.88), bottom: hex(0x285447, 0.92)), isDeep: false, sky: hex(0x8FD3BE, 1)),
        ]
    }()

    var frontChanged: ((NSColor?) -> Void)?
    /// Fanned open, as if you could flip through them (the pointer is over the deck).
    var isOpen = false { didSet { if oldValue != isOpen { arrange(animated: true) } } }

    private let stage = CALayer()
    private var sheets: [SpaceSheet] = []
    private var front = 0
    private var tilt = CGPoint.zero
    private let pause = OcclusionPause()
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.addSublayer(stage)
        // Back to front, so each sheet's shadow falls on the ones behind it.
        for i in Self.spaces.indices {
            let sheet = SpaceSheet()
            sheet.showsSidebar = i == 0
            sheets.append(sheet)
        }
        sheets.reversed().forEach { stage.addSublayer($0.root) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether a point (in this view) is over the deck.
    func contains(_ point: CGPoint) -> Bool {
        let center = CGPoint(x: bounds.midX - 60, y: bounds.midY + 30)
        return CGRect(x: center.x - 240, y: center.y - 250, width: 460, height: 500).contains(point)
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            stage.bounds = CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height)
            stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        arrange(animated: false)
        applyTilt(animated: false)
        startFloat()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pause.attach(stage, to: window)
        timer?.invalidate()
        timer = nil
        refresh(animated: false)
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !Tokens.Motion.reduceMotion, self.window?.occlusionState.contains(.visible) == true, !self.isOpen else { return }
                self.advance()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        stage.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    /// Holds a space in front and stops the turning (for a capture).
    func hold(_ index: Int) {
        timer?.invalidate()
        timer = nil
        front = (index % Self.spaces.count + Self.spaces.count) % Self.spaces.count
        refresh(animated: false)
    }

    /// The next space comes to the front: every sheet takes the next one's color, gently.
    func advance() {
        front = (front + 1) % Self.spaces.count
        refresh(animated: true)
    }

    private func refresh(animated: Bool) {
        let dark = effectiveAppearance.isDark
        for (i, sheet) in sheets.enumerated() {
            let index = (front + i) % Self.spaces.count
            sheet.show(Self.spaces[index], index: index, isDark: dark, animated: animated)
        }
        frontChanged?(Self.spaces[front].sky)
        stage.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    /// Fanned back and up to the left, each a little farther off and turned a little more; open, they spread.
    private func arrange(animated: Bool) {
        let spread: CGFloat = isOpen && !Tokens.Motion.reduceMotion ? 1.4 : 1
        MaterialMotion.animate(animated ? 0.45 : 0, moves: true) {
            for (i, sheet) in sheets.enumerated() {
                let k = CGFloat(i)
                sheet.root.position = CGPoint(x: -20 - k * 50 * spread, y: 4 + k * 30 * spread)
                let turn = CATransform3DMakeRotation(k * 5 * spread * .pi / 180, 0, 0, 1)
                sheet.root.transform = CATransform3DConcat(turn, CATransform3DMakeTranslation(0, 0, -k * 80 * spread))
                // Farther back, a little lost in the air.
                sheet.root.opacity = Float(1 - k * 0.12)
            }
        }
    }

    func setTilt(_ point: CGPoint) {
        tilt = point
        applyTilt(animated: true)
    }

    private func applyTilt(animated: Bool) {
        let t = Tokens.Motion.reduceMotion ? .zero : tilt
        MaterialMotion.animate(animated ? Tokens.Material.follow : 0) {
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / 1000
            let radians = Tokens.Material.tilt * .pi / 180
            // At rest the deck faces a little toward the text, leaning back.
            let turn = CATransform3DConcat(CATransform3DMakeRotation(-(6 * .pi / 180) - t.y * radians, 1, 0, 0),
                                           CATransform3DMakeRotation(-(16 * .pi / 180) + t.x * radians, 0, 1, 0))
            stage.sublayerTransform = CATransform3DConcat(turn, perspective)
            sheets.forEach { $0.setLight(t) }
        }
    }

    /// The deck floats a few points up and down on a slow loop.
    private func startFloat() {
        sheets.forEach { $0.root.removeAnimation(forKey: "float") }
        guard !Tokens.Motion.reduceMotion else { return }
        for sheet in sheets {
            let float = CABasicAnimation(keyPath: "transform.translation.y")
            float.fromValue = -4
            float.toValue = 4
            float.duration = 3.6
            float.isAdditive = true
            float.autoreverses = true
            float.repeatCount = .infinity
            float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            float.isRemovedOnCompletion = false
            sheet.root.add(float, forKey: "float")
        }
    }
}
#endif

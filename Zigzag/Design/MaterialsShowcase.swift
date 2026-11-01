#if DEBUG
import AppKit

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Materials"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = hero
        // Nothing is being typed until you choose to: the window starts with the hero, not the field.
        window.initialFirstResponder = hero
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }

    /// `materials [light|dark|system]`, `materials id <path>` (the window number), `materials tilt <x> <y>`,
    /// `materials state <primary|secondary|toggle|field|tile> <rest|hover|press|on|off|focus>`, `materials close`.
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
            let info = "\(window.windowNumber)"
            if words.count > 1 { try? info.write(toFile: words[1], atomically: true, encoding: .utf8) }
        case "tilt":
            let n = words.dropFirst().compactMap { Double($0) }
            if n.count == 2 { shared.hero.point(at: CGPoint(x: n[0], y: n[1])) }
        case "state":
            if words.count == 3 { shared.hero.debugState(words[1], words[2]) }
        default: break
        }
    }
}

/// Onboarding's first screen, as the kit makes it: a sky; a wall of real sites' tiles in perspective, drifting a
/// little and turning toward the pointer; and one glass panel with the wordmark and the first things to do.
final class MaterialsHero: NSView {
    private let sky = SkyBackdrop()
    private let wall = TileWall()
    private let panel = GlassSurface()
    private let wordmark = EmbossedWordmark()
    let field = RecessedField(placeholder: "Search or enter address", symbol: "magnifyingglass")
    let toggle = TactileToggle(title: "Make Zigzag your default browser", isOn: true)
    let secondary = TactileButton(title: "Import from Chrome", style: .secondary)
    let primary = TactileButton(title: "Get Started", style: .primary)
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        [sky, wall, panel].forEach { addSubview($0) }
        [wordmark, field, toggle, secondary, primary].forEach { panel.contentView.addSubview($0) }
        primary.onClick = { _ in }
        secondary.onClick = { _ in }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private static let panelWidth: CGFloat = 440
    private static let pad: CGFloat = Tokens.Space.x10
    private static let markHeight: CGFloat = 46

    private var panelHeight: CGFloat {
        let h = Tokens.Material.controlHeight
        return Self.pad + Self.markHeight + Tokens.Space.x10 + h + Tokens.Space.x3 + Tokens.Space.x8 + Tokens.Space.x6 + h + Self.pad
    }

    override func layout() {
        super.layout()
        sky.frame = bounds
        wall.frame = bounds
        let size = NSSize(width: Self.panelWidth, height: panelHeight)
        panel.frame = NSRect(x: round(bounds.midX - size.width / 2), y: round(bounds.height * 0.47 - size.height / 2), width: size.width, height: size.height)
        let inner = Self.panelWidth - Self.pad * 2
        let h = Tokens.Material.controlHeight
        var y = size.height - Self.pad - Self.markHeight
        let markWidth = Self.markHeight * WordmarkView.aspect
        wordmark.frame = NSRect(x: round((size.width - markWidth) / 2), y: y, width: markWidth, height: Self.markHeight)
        y -= Tokens.Space.x10 + h
        field.frame = NSRect(x: Self.pad, y: y, width: inner, height: h)
        y -= Tokens.Space.x3 + Tokens.Space.x8
        toggle.frame = NSRect(x: Self.pad + Tokens.Space.x1, y: y, width: inner - Tokens.Space.x1, height: Tokens.Space.x8)
        y -= Tokens.Space.x6 + h
        let half = (inner - Tokens.Space.x3) / 2
        secondary.frame = NSRect(x: Self.pad, y: y, width: half, height: h)
        primary.frame = NSRect(x: Self.pad + half + Tokens.Space.x3, y: y, width: half, height: h)
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
        point(at: CGPoint(x: (p.x - bounds.midX) / (bounds.width / 2), y: (p.y - bounds.midY) / (bounds.height / 2)))
        wall.hover(at: convert(p, to: wall))
    }

    override func mouseExited(with event: NSEvent) {
        point(at: .zero)
        wall.hover(at: nil)
    }

    /// Everything turns toward and is lit from the pointer, x and y in -1...1 from the middle.
    func point(at raw: CGPoint) {
        let p = CGPoint(x: max(-1, min(1, raw.x)), y: max(-1, min(1, raw.y)))
        wall.setTilt(p)
        panel.light = p
        // The wordmark sits high in the panel: the light is measured from it.
        wordmark.light = CGPoint(x: p.x * 1.4, y: p.y)
    }

    /// Return is Get Started.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           !(window?.firstResponder is NSTextView) {
            primary.onClick?(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func debugState(_ name: String, _ state: String) {
        switch name {
        case "primary", "secondary":
            let button = name == "primary" ? primary : secondary
            button.isHovered = state == "hover" || state == "press"
            button.isPressed = state == "press"
        case "toggle": toggle.isOn = state == "on"
        case "field": window?.makeFirstResponder(state == "focus" ? field.field : self)
        case "tile": wall.debugLift(state == "hover")
        default: break
        }
    }
}

/// Real sites as raised tiles on a gently curved wall, seen in perspective: the outer ones farther off and turned
/// toward the middle, each drifting on its own slow loop, the whole wall turning a few degrees toward the pointer.
final class TileWall: NSView {
    private let stage = CALayer()
    private var tiles: [RaisedTileLayers] = []
    private var hovered: RaisedTileLayers?
    private var tilt = CGPoint.zero
    private let pause = OcclusionPause()
    private var driftSize: CGSize = .zero

    private static let columns = 9, rows = 5
    private static let side: CGFloat = 64
    private static let pitch: CGFloat = 132
    /// The wall leans back at the top, so it reads as a surface in space rather than a pattern.
    private static let lean: CGFloat = 7

    /// Sites, with a symbol and color for when their icon can't be had.
    private static let sites: [(host: String, symbol: String, color: UInt32)] = [
        ("google.com", "magnifyingglass", 0x4285F4), ("github.com", "chevron.left.forwardslash.chevron.right", 0x24292F),
        ("wikipedia.org", "book.closed", 0x54595D), ("youtube.com", "play.fill", 0xFF0033),
        ("notion.so", "doc.text", 0x2F3437), ("figma.com", "pencil.and.outline", 0xA259FF),
        ("linear.app", "line.3.horizontal", 0x5E6AD2), ("apple.com", "applelogo", 0x1D1D1F),
        ("spotify.com", "music.note", 0x1DB954), ("reddit.com", "bubble.left.and.bubble.right", 0xFF4500),
        ("stripe.com", "creditcard", 0x635BFF), ("slack.com", "number", 0x4A154B),
        ("airbnb.com", "house", 0xFF385C), ("nytimes.com", "newspaper", 0x121212),
        ("dropbox.com", "shippingbox", 0x0061FF), ("duolingo.com", "character.bubble", 0x58CC02),
        ("claude.ai", "asterisk", 0xD97757), ("discord.com", "gamecontroller", 0x5865F2),
        ("vercel.com", "triangle.fill", 0x000000), ("framer.com", "square.on.square", 0x0099FF),
        ("dribbble.com", "basketball", 0xEA4C89), ("pinterest.com", "pin", 0xE60023),
        ("nasa.gov", "globe.americas", 0x0B3D91), ("maps.apple.com", "map", 0x34C759),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(stage)
        for row in 0..<Self.rows {
            for column in 0..<Self.columns {
                let tile = RaisedTileLayers()
                let site = Self.sites[Self.siteIndex(column: column, row: row)]
                tile.finish = .porcelain(tint: Tokens.Color.hex(site.color))
                tile.layout(side: Self.side)
                stage.addSublayer(tile.root)
                tiles.append(tile)
            }
        }
        // A soft vignette, so the wall dissolves into the sky at its edges instead of being cut by the window.
        let fade = CAGradientLayer()
        fade.type = .radial
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        fade.locations = [0, 0.55, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0.5)
        fade.endPoint = CGPoint(x: 1.08, y: 1.12)
        layer?.mask = fade
        loadIcons()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Neighbors never repeat: across a row the sites step by 5, down a column by 7.
    private static func siteIndex(column: Int, row: Int) -> Int { (column * 5 + row * 7) % sites.count }

    private func loadIcons() {
        for (index, site) in Self.sites.enumerated() {
            let fallback = { [weak self] in
                guard let self else { return }
                let image = MaterialImages.symbol(site.symbol, color: .white, size: 26)
                self.setIcon(image, finish: .color(Tokens.Color.hex(site.color)), site: index)
            }
            guard let url = URL(string: "https://www.google.com/s2/favicons?domain=\(site.host)&sz=128") else { continue }
            if let cached = URL(string: "https://\(site.host)").flatMap({ FaviconStore.shared.cachedIcon(for: $0) }), FaviconStore.sharpSide(of: cached) >= 48 {
                setIcon(cached, finish: .porcelain(tint: Tokens.Color.hex(site.color)), site: index)
                continue
            }
            Task { @MainActor [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data), image.isValid,
                      (image.representations.map(\.pixelsWide).max() ?? 0) >= 48 else { fallback(); return }
                self?.setIcon(image, finish: .porcelain(tint: Tokens.Color.hex(site.color)), site: index)
            }
        }
    }

    private func setIcon(_ image: NSImage?, finish: RaisedTileLayers.Finish, site: Int) {
        for row in 0..<Self.rows {
            for column in 0..<Self.columns where Self.siteIndex(column: column, row: row) == site {
                let tile = tiles[row * Self.columns + column]
                tile.finish = finish
                tile.image = image
                tile.fillsFace = image.map(Self.fillsSquare) ?? false
            }
        }
    }

    /// Whether an icon is a square design of its own: solid all the way to the middle of each edge.
    private static func fillsSquare(_ image: NSImage) -> Bool {
        let n = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        let edges = [(n / 2, 1), (1, n / 2), (n - 2, n / 2), (n / 2, n - 2), (n / 4, 1), (3 * n / 4, n - 2)]
        return edges.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.95 }
    }

    override func layout() {
        super.layout()
        Tokens.Motion.withoutAnimation {
            // The stage's own coordinates start at its middle, so the wall turns about its middle.
            stage.bounds = CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height)
            stage.position = CGPoint(x: bounds.midX, y: bounds.midY - bounds.height * 0.02)
            layer?.mask?.frame = bounds
            let halfW = CGFloat(Self.columns - 1) / 2, halfH = CGFloat(Self.rows - 1) / 2
            for row in 0..<Self.rows {
                for column in 0..<Self.columns {
                    let tile = tiles[row * Self.columns + column]
                    let nx = (CGFloat(column) - halfW) / halfW, ny = (CGFloat(row) - halfH) / halfH
                    // A shallow bowl: the farther from the middle, the farther back, turned to face the middle.
                    let z = -(nx * nx * 240 + ny * ny * 120)
                    tile.root.position = CGPoint(x: (CGFloat(column) - halfW) * Self.pitch, y: (CGFloat(row) - halfH) * Self.pitch)
                    let turn = CATransform3DConcat(CATransform3DMakeRotation(-ny * 12 * .pi / 180, 1, 0, 0), CATransform3DMakeRotation(nx * 16 * .pi / 180, 0, 1, 0))
                    tile.root.transform = CATransform3DConcat(turn, CATransform3DMakeTranslation(0, 0, z))
                    // Farther off, a little lost in the air.
                    tile.root.opacity = Float(1 + z / 900)
                }
            }
        }
        applyTilt(animated: false)
        if bounds.size != driftSize { startDrift() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pause.attach(stage, to: window)
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        stage.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    private func applyAppearance() {
        let dark = effectiveAppearance.isDark
        tiles.forEach { $0.isDark = dark }
        stage.applyContentsScale(window?.backingScaleFactor ?? 2)
    }

    func setTilt(_ point: CGPoint) {
        tilt = point
        applyTilt(animated: true)
    }

    private func applyTilt(animated: Bool) {
        let still = Tokens.Motion.reduceMotion
        let t = still ? .zero : tilt
        MaterialMotion.animate(animated ? Tokens.Material.follow : 0) {
            var perspective = CATransform3DIdentity
            perspective.m34 = Tokens.Material.perspective * 0.8
            let radians = Tokens.Material.tilt * .pi / 180
            let turn = CATransform3DConcat(CATransform3DMakeRotation(-(Self.lean * .pi / 180) - t.y * radians, 1, 0, 0),
                                           CATransform3DMakeRotation(t.x * radians, 0, 1, 0))
            // A little parallax: the wall slides against the pointer, as something farther off does.
            let shift = CATransform3DMakeTranslation(-t.x * 10, -t.y * 8, 0)
            stage.sublayerTransform = CATransform3DConcat(CATransform3DConcat(turn, shift), perspective)
            tiles.forEach { $0.setTilt(t, turns: false, animated: false) }
        }
    }

    /// Lifts the tile under a point (in this view), and sets down the last one.
    func hover(at point: CGPoint?) {
        var found: RaisedTileLayers?
        if let point, let hit = stage.presentation()?.hitTest(point)?.model() {
            found = tiles.first { tile in
                var layer: CALayer? = hit
                while let current = layer { if current === tile.root { return true }; layer = current.superlayer }
                return false
            }
        }
        guard found !== hovered else { return }
        hovered?.setLifted(false, animated: true)
        found?.setLifted(true, animated: true)
        hovered = found
    }

    func debugLift(_ lifted: Bool) {
        let tile = tiles[2 * Self.columns + 2]
        hovered?.setLifted(false, animated: false)
        tile.setLifted(lifted, animated: false)
        hovered = lifted ? tile : nil
    }

    /// Each tile bobs on its own slow loop, out of step with the rest, so the wall breathes without repeating.
    private func startDrift() {
        driftSize = bounds.size
        tiles.forEach { $0.root.removeAnimation(forKey: "drift") }
        guard !Tokens.Motion.reduceMotion else { return }
        var generator = SystemRandomNumberGenerator()
        for tile in tiles {
            let drift = CABasicAnimation(keyPath: "transform.translation.y")
            drift.fromValue = -CGFloat.random(in: 3...6, using: &generator)
            drift.toValue = CGFloat.random(in: 3...6, using: &generator)
            drift.duration = Double.random(in: 5.5...9, using: &generator)
            drift.timeOffset = Double.random(in: 0...drift.duration, using: &generator)
            drift.isAdditive = true
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.isRemovedOnCompletion = false
            tile.root.add(drift, forKey: "drift")
        }
    }
}
#endif

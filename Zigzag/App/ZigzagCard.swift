import AppKit
import UniformTypeIdentifiers

// MARK: - When you started

/// The day Zigzag was first used on this Mac and the version it started on: decided once, at the first launch that
/// knows to keep it, and never moved after.
enum CardStart {
    struct Record: Equatable {
        var date: Date
        var version: String
        /// False when Zigzag was in use before it kept this: the version is then the earliest one on record.
        var isExact: Bool
    }

    /// The defaults it's kept in; a test's own keeps yours out of it.
    static var defaults: UserDefaults = .standard
    static let dateKey = "FirstLaunchDate"
    static let versionKey = "FirstLaunchVersion"
    static let exactKey = "FirstLaunchVersionExact"
    /// Zigzag didn't exist before 2026: an older date on disk belongs to a copied or odd file, not to a start.
    static let earliestPossible = Date(timeIntervalSince1970: 1_767_225_600)
    /// Data younger than this on a Mac with no earlier run recorded is this very launch's.
    static let freshWindow: TimeInterval = 60 * 60

    static var stored: Record? {
        guard let date = defaults.object(forKey: dateKey) as? Date, let version = defaults.string(forKey: versionKey) else { return nil }
        return Record(date: date, version: version, isExact: defaults.bool(forKey: exactKey))
    }

    /// At launch, before this run is recorded as the last one: keeps the start the first time, and returns what's kept.
    @discardableResult
    static func settle(now: Date = Date(), version: String = VersionName.running, root: URL = Paths.support) -> Record {
        if let stored { return stored }
        let record = choose(now: now, version: version, dates: dates(in: root), lastRun: defaults.string(forKey: "LastRunVersion"),
                            backups: backupVersions(in: root), launches: defaults.integer(forKey: "LaunchCount"))
        defaults.set(record.date, forKey: dateKey)
        defaults.set(record.version, forKey: versionKey)
        defaults.set(record.isExact, forKey: exactKey)
        return record
    }

    /// The earliest sign of Zigzag on this Mac, and the version: this one on a fresh install, else the earliest on record.
    static func choose(now: Date, version: String, dates: [Date], lastRun: String?, backups: [String], launches: Int) -> Record {
        let start = dates.filter { $0 >= earliestPossible && $0 <= now }.min() ?? now
        let fresh = lastRun == nil && backups.isEmpty && launches == 0 && now.timeIntervalSince(start) < freshWindow
        if fresh { return Record(date: start, version: version, isExact: true) }
        let known = ([lastRun].compactMap { $0 } + backups + [version]).filter { !$0.isEmpty }
        return Record(date: start, version: known.min(by: isEarlier) ?? version, isExact: false)
    }

    /// When the data folder and the first files Zigzag writes in it were made, and when each update backup was.
    static func dates(in root: URL) -> [Date] {
        let files = [root] + ["Library.json", "Session.json", "History.sqlite", "Profiles.json"].map { root.appendingPathComponent($0) }
        let made = files.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
        return made + UpdateBackup.all(in: root).compactMap { UpdateBackup.date(of: $0.lastPathComponent) }
    }

    /// The versions update backups were made from, from their names ("2026-10-02T09-00-00Z 0.4.0").
    static func backupVersions(in root: URL) -> [String] {
        UpdateBackup.all(in: root).compactMap { url in
            let words = url.lastPathComponent.split(separator: " ")
            guard words.count >= 2, words[1].first?.isNumber == true else { return nil }
            return String(words[1])
        }
    }

    /// 0.9.2-beta.1 before 0.9.2 before 0.10.0.
    static func isEarlier(_ a: String, than b: String) -> Bool {
        func split(_ v: String) -> (base: [Int], tag: [Int]?) {
            let halves = v.split(separator: "-", maxSplits: 1)
            let numbers: (Substring) -> [Int] = { $0.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 } }
            return (numbers(halves.first ?? ""), halves.count > 1 ? numbers(halves[1]) : nil)
        }
        func less(_ x: [Int], _ y: [Int]) -> Bool? {
            for i in 0..<max(x.count, y.count) {
                let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
                if p != q { return p < q }
            }
            return nil
        }
        let x = split(a), y = split(b)
        if let base = less(x.base, y.base) { return base }
        switch (x.tag, y.tag) {
        case let (p?, q?): return less(p, q) ?? false
        case (.some, nil): return true
        default: return false
        }
    }

    /// Before 1.0, every version is a beta.
    static func isBeta(_ version: String) -> Bool {
        guard let major = version.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) else { return false }
        return major < 1
    }
}

// MARK: - What's on it

/// What the card says: only facts this Mac knows.
struct CardFace: Equatable {
    var name: String
    var start: Date
    var version: String
    var isExact: Bool
    var day: Int

    static func current(now: Date = Date()) -> CardFace {
        let record = CardStart.settle(now: now)
        return CardFace(name: NSFullUserName(), start: record.date, version: record.version, isExact: record.isExact,
                        day: day(from: record.date, to: now))
    }

    /// Day 1 is the first day.
    static func day(from start: Date, to now: Date, calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0
        return max(1, days + 1)
    }

    var sinceLine: String {
        let formatter = DateFormatter()
        formatter.locale = Words.dates
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let date = formatter.string(from: start)
        return String(localized: "Using Zigzag since \(date)", comment: "On Your Zigzag Card: the day Zigzag was first used on this Mac.")
    }

    var versionLine: String {
        let shown = VersionName.display(version)
        return isExact
            ? String(localized: "Started on \(shown)", comment: "On Your Zigzag Card: the version of Zigzag first used on this Mac.")
            : String(localized: "Started on \(shown) or earlier",
                     comment: "On Your Zigzag Card: the earliest version Zigzag has on record for this Mac, when it was in use before it kept the first one.")
    }

    var betaLine: String? {
        CardStart.isBeta(version) ? String(localized: "Joined in the beta", comment: "On Your Zigzag Card: Zigzag was first used here before version 1.0.") : nil
    }

    var dayLine: String { String(localized: "Day \(day)", comment: "On Your Zigzag Card: how many days since Zigzag was first used here, counting the first as 1.") }

    /// Everything on it, for VoiceOver.
    var spoken: String { ([name] + [sinceLine, versionLine, betaLine, dayLine].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// The card's colors, from the space in front: its hue, and a second one when the space has a gradient. White, gray
/// and black spaces take Zigzag's own blue.
struct CardPalette: Equatable {
    var hue: Double
    var hue2: Double?

    static func of(_ space: SpaceInfo?) -> CardPalette {
        let theme = Brand.Theme.of(space)
        guard let space, let hue = theme.surfaceHue else { return CardPalette(hue: Brand.navyHue, hue2: nil) }
        return CardPalette(hue: hue, hue2: space.background2 == nil ? nil : space.hue2)
    }

    /// The face, lighter at its top left: pale by day, deep at night, as the frame is.
    var top: NSColor { tone(hue, light: (0.94, 0.04), dark: (0.42, 0.06)) }
    var bottom: NSColor { tone(hue2 ?? hue, light: (0.86, 0.055), dark: (0.29, 0.055)) }
    /// The name and the wordmark, then the quiet lines: at least 4.5:1 on either end of the face.
    var ink: NSColor { tone(hue, light: (0.27, 0.05), dark: (0.97, 0.012)) }
    var quiet: NSColor { tone(hue, light: (0.42, 0.06), dark: (0.84, 0.03)) }

    private func tone(_ h: Double, light: (Double, Double), dark: (Double, Double)) -> NSColor {
        Tokens.Color.dynamic(light: SpaceColor.tone(hue: h, lightness: light.0, chroma: light.1),
                             dark: SpaceColor.tone(hue: h, lightness: dark.0, chroma: dark.1))
    }
}

// MARK: - Drawing it

/// Draws the face, the same for the window and the saved picture: color, a fine grain, a lit edge, the wordmark and
/// the words. Nothing else goes on it.
enum CardArt {
    /// The face as a picture `scale` pixels per point, drawn in `appearance`.
    static func image(_ face: CardFace, palette: CardPalette, appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        let size = Tokens.Keepsake.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Drawn top down, as text is laid out.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        appearance.performAsCurrentDrawingAppearance { draw(face, palette: palette, in: CGRect(origin: .zero, size: size), context: context) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The saved picture: the face at `Keepsake.exportScale`, as PNG.
    static func png(_ face: CardFace, palette: CardPalette, appearance: NSAppearance, scale: CGFloat = Tokens.Keepsake.exportScale) -> Data? {
        guard let image = image(face, palette: palette, appearance: appearance, scale: scale) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = Tokens.Keepsake.size
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(_ face: CardFace, palette: CardPalette, in rect: CGRect, context: CGContext) {
        let shape = CGPath(roundedRect: rect, cornerWidth: Tokens.Keepsake.radius, cornerHeight: Tokens.Keepsake.radius, transform: nil)
        context.addPath(shape)
        context.clip()
        let colors = [palette.top.cgColor, palette.bottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        // Grain, as printed card stock has.
        var noiseRect = CGRect(origin: .zero, size: BrandSurface.noise.size)
        if let noise = BrandSurface.noise.cgImage(forProposedRect: &noiseRect, context: nil, hints: nil) {
            context.saveGState()
            context.setBlendMode(.overlay)
            context.setAlpha(0.05)
            context.draw(noise, in: noiseRect, byTiling: true)
            context.restoreGState()
        }
        // The edge catches the light, more along the top.
        let dark = NSAppearance.currentDrawing().isDark
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: Tokens.Keepsake.radius - 0.5,
                               cornerHeight: Tokens.Keepsake.radius - 0.5, transform: nil))
        context.setLineWidth(1)
        context.replacePathWithStrokedPath()
        context.clip()
        let rim = [NSColor.white.withAlphaComponent(dark ? 0.16 : 0.7).cgColor, NSColor.white.withAlphaComponent(dark ? 0.03 : 0.15).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: rim, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        context.restoreGState()

        let pad = Tokens.Keepsake.pad
        let ink = palette.ink, quiet = palette.quiet
        // The wordmark, top left; its outline is drawn y up, so it's flipped into place.
        let markHeight = Tokens.Keepsake.wordmarkHeight
        let mark = CGRect(x: rect.minX + pad, y: rect.minY + pad, width: ceil(markHeight * WordmarkView.aspect), height: markHeight)
        var flip = CGAffineTransform(translationX: 0, y: mark.minY + mark.maxY).scaledBy(x: 1, y: -1)
        if let outline = WordmarkView.outline(in: mark).copy(using: &flip) {
            context.addPath(outline)
            context.setFillColor(ink.cgColor)
            context.fillPath()
        }

        // Top right, level with the wordmark: the version it started on, the beta under it.
        let small = Tokens.Font.detail()
        let step = lineHeight(small)
        let first = mark.maxY
        let markEnd = mark.maxX + Tokens.Space.x4
        for (i, line) in [face.versionLine, face.betaLine].compactMap({ $0 }).enumerated() {
            draw(text(line, font: small, color: quiet, alignment: .right), baseline: first + CGFloat(i) * step, font: small,
                 x: markEnd, width: rect.maxX - pad - markEnd)
        }

        // At the foot: the name over the day it began, and the day count at the end of that line.
        let lower = rect.maxY - pad
        let figures = Tokens.Font.figures(Tokens.TypeSize.label)
        let dayWidth = ceil(text(face.dayLine, font: figures, color: quiet).size().width)
        draw(text(face.dayLine, font: figures, color: quiet, alignment: .right), baseline: lower, font: figures,
             x: rect.maxX - pad - dayWidth, width: dayWidth)
        let textWidth = rect.width - pad * 2 - dayWidth - Tokens.Space.x4
        draw(text(face.sinceLine, font: small, color: quiet), baseline: lower, font: small, x: rect.minX + pad, width: textWidth)
        if !face.name.isEmpty {
            let font = Tokens.Font.voice(Tokens.Keepsake.nameSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            draw(Tokens.Font.voiceText(face.name, size: Tokens.Keepsake.nameSize, color: ink, paragraph: paragraph),
                 baseline: lower - step - Tokens.Space.x2, font: font, x: rect.minX + pad, width: rect.width - pad * 2)
        }
    }

    private static func text(_ string: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// One line with its baseline at `baseline` (top down).
    private static func draw(_ string: NSAttributedString, baseline: CGFloat, font: NSFont, x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        string.draw(with: CGRect(x: x, y: baseline - font.ascender, width: width, height: lineHeight(font)),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - The card in its window

/// The card as an object: it floats on two soft shadows, leans a few degrees toward the pointer with a sheen that
/// follows it, and settles back when the pointer goes. With Reduce Motion it holds still, the sheen at rest.
final class CardStage: NSView {
    private let card = CALayer()
    /// Flat, so the leaning card is drawn into its plane and never dips behind the shadows beside it.
    private let holder = CALayer()
    private let sheen = CAGradientLayer()
    private let ambient = CALayer()
    private let contact = CALayer()
    var face: CardFace { didSet { if face != oldValue { redraw() } } }
    var palette: CardPalette { didSet { if palette != oldValue { redraw() } } }
    /// Where the pointer is over the card, -1 to 1 from its middle (y up); nil at rest.
    private(set) var lean: CGPoint?

    init(face: CardFace, palette: CardPalette) {
        self.face = face
        self.palette = palette
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = false
        let radius = Tokens.Keepsake.radius
        for shadow in [ambient, contact] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOffset = .zero
            layer?.addSublayer(shadow)
        }
        card.cornerRadius = radius
        card.cornerCurve = .continuous
        card.masksToBounds = true
        card.contentsGravity = .resize
        sheen.type = .radial
        sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 1)
        card.addSublayer(sheen)
        holder.addSublayer(card)
        layer?.addSublayer(holder)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Your Zigzag Card", comment: "Title of the window with Your Zigzag Card, and its name for VoiceOver."))
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redraw()
    }

    override func layout() {
        super.layout()
        let size = Tokens.Keepsake.size
        let frame = CGRect(x: round((bounds.width - size.width) / 2), y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
        Tokens.Motion.withoutAnimation {
            holder.frame = bounds
            card.bounds = CGRect(origin: .zero, size: size)
            card.position = CGPoint(x: frame.midX, y: frame.midY)
            sheen.frame = sheenFrame(for: lean)
            let path = CGPath(roundedRect: frame, cornerWidth: Tokens.Keepsake.radius, cornerHeight: Tokens.Keepsake.radius, transform: nil)
            for (shadow, drop) in [(ambient, Tokens.Keepsake.ambientDrop), (contact, Tokens.Keepsake.contactDrop)] {
                shadow.frame = bounds
                shadow.shadowPath = path.copy(using: [CGAffineTransform(translationX: 0, y: -drop)])
            }
        }
    }

    private func redraw() {
        let appearance = effectiveAppearance
        let dark = appearance.isDark
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        Tokens.Motion.withoutAnimation {
            card.contents = CardArt.image(face, palette: palette, appearance: appearance, scale: scale)
            card.contentsScale = scale
            ambient.shadowRadius = Tokens.Keepsake.ambientRadius
            ambient.shadowOpacity = dark ? 0.5 : 0.16
            contact.shadowRadius = Tokens.Keepsake.contactRadius
            contact.shadowOpacity = dark ? 0.45 : 0.14
            sheen.colors = [NSColor.white.withAlphaComponent(dark ? 0.12 : 0.24).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            sheen.opacity = lean == nil || Tokens.Motion.reduceMotion ? 0.55 : 1
        }
        setAccessibilityValue(face.spoken)
    }

    /// The sheen's light, where the pointer is; at rest, up at the top left.
    private func sheenFrame(for lean: CGPoint?) -> CGRect {
        let size = Tokens.Keepsake.size
        let point = Tokens.Motion.reduceMotion ? nil : lean
        let center = CGPoint(x: size.width * (0.5 + (point?.x ?? -0.55) * 0.5), y: size.height * (0.5 + (point?.y ?? 0.7) * 0.5))
        let side = size.width * 1.3
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Leans toward `point` (-1 to 1 each way from the card's middle, y up), or settles back with nil.
    func lean(toward point: CGPoint?) {
        let point = point.map { CGPoint(x: min(max($0.x, -1), 1), y: min(max($0.y, -1), 1)) }
        let settling = point == nil
        lean = point
        let still = Tokens.Motion.reduceMotion
        let role = settling ? Tokens.Motion.Role.present : .feedback
        let duration = role.duration(entering: !settling)
        var transform = CATransform3DIdentity
        if let point, !still {
            let most = Tokens.Keepsake.tilt * .pi / 180
            transform.m34 = -1 / Tokens.Keepsake.perspective
            // Its face turns to the pointer: the side nearest it goes back.
            transform = CATransform3DRotate(transform, point.x * most, 0, 1, 0)
            transform = CATransform3DRotate(transform, -point.y * most, 1, 0, 0)
        }
        let from = card.presentation()?.transform ?? card.transform
        card.transform = transform
        if !still, duration > 0 {
            let move = Tokens.Motion.easeAnimation(keyPath: "transform", duration: duration, timing: role.timing)
            move.fromValue = NSValue(caTransform3D: from)
            move.toValue = NSValue(caTransform3D: transform)
            card.add(move, forKey: "lean")
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(still ? 0 : duration)
        CATransaction.setAnimationTimingFunction(role.timing)
        sheen.frame = sheenFrame(for: point)
        sheen.opacity = point == nil || still ? 0.55 : 1
        CATransaction.commit()
    }

    /// Where a point in this view sits over the card, -1 to 1 each way from its middle.
    func leanPoint(for location: NSPoint) -> CGPoint {
        let size = Tokens.Keepsake.size
        return CGPoint(x: (location.x - bounds.midX) / (size.width / 2), y: (location.y - bounds.midY) / (size.height / 2))
    }
}

/// The window's content: the card, and Save as Image… and Share… under it.
private final class CardView: NSView {
    let stage: CardStage
    let save = PillButton(title: String(localized: "Save as Image…", comment: "Button under Your Zigzag Card: saves it as a PNG picture, asking where."))
    let share = PillButton(title: String(localized: "Share…", comment: "Button under Your Zigzag Card: opens the Mac's share menu with its picture."))
    private var tracking: NSTrackingArea?

    init(face: CardFace, palette: CardPalette) {
        stage = CardStage(face: face, palette: palette)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        [stage, save, share].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static var size: NSSize {
        let k = Tokens.Keepsake.self
        return NSSize(width: k.size.width + k.margin * 2, height: k.top + k.size.height + k.buttonGap + Tokens.Page.controlHeight + k.bottom)
    }

    override func layout() {
        super.layout()
        let k = Tokens.Keepsake.self
        // The stage runs to the window's edges, so the shadow and the lean have room; the card sits in its middle.
        stage.frame = NSRect(x: 0, y: 0, width: bounds.width, height: (k.top + k.size.height / 2) * 2)
        let height = Tokens.Page.controlHeight
        let widths = [save.fittingWidth, share.fittingWidth]
        var x = round((bounds.width - widths.reduce(0, +) - Tokens.Space.x2) / 2)
        let y = k.top + k.size.height + k.buttonGap
        for (button, width) in zip([save, share], widths) {
            button.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + Tokens.Space.x2
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }
    override func mouseEntered(with event: NSEvent) { follow(event) }
    override func mouseExited(with event: NSEvent) { stage.lean(toward: nil) }

    private func follow(_ event: NSEvent) {
        let point = stage.leanPoint(for: stage.convert(event.locationInWindow, from: nil))
        // Only near the card: over the buttons it rests.
        let near = abs(point.x) <= 1.25 && abs(point.y) <= 1.25
        stage.lean(toward: near ? point : nil)
    }
}

/// Zigzag › Your Zigzag Card…: one card in a small window, in the colors of the space in front.
final class ZigzagCardWindowController: NSWindowController, NSWindowDelegate, SpaceTinted {
    private(set) static var shared: ZigzagCardWindowController?
    private let content: CardView
    private(set) var space: SpaceInfo?
    private var themeToken: SignalToken?
    private let sharing = SharingWatch()
    var tintSpace: SpaceInfo? { space }

    private static var frontSpace: SpaceInfo? {
        (WindowManager.shared.keyController ?? WindowManager.shared.controllers.first)?.tabManager.currentSpace
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let shared {
            shared.refresh()
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ZigzagCardWindowController()
        shared = controller
        controller.showWindow(nil)
    }

    private init() {
        space = Self.frontSpace
        content = CardView(face: .current(), palette: .of(space))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: CardView.size), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = String(localized: "Your Zigzag Card", comment: "Title of the window with Your Zigzag Card, and its name for VoiceOver.")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = true
        window.backgroundColor = Tokens.Color.formBackground
        window.contentView = content
        window.center()
        super.init(window: window)
        window.delegate = self
        content.save.onClick = { [weak self] _ in self?.saveImage() }
        content.share.onClick = { [weak self] _ in self?.shareImage() }
        themeToken = Brand.themeChanged.observe { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }

    /// The space in front and today, again.
    private func refresh() {
        // While this window is key, the space in front is the last browser window's.
        if let front = Self.frontSpace { space = front }
        content.stage.palette = .of(space)
        content.stage.face = .current()
        [content.save, content.share].forEach { $0.stateDidChange(animated: false) }
    }

    private var png: Data? {
        CardArt.png(content.stage.face, palette: content.stage.palette, appearance: content.effectiveAppearance)
    }

    private static var fileName: String { String(localized: "Zigzag Card", comment: "File name of Your Zigzag Card saved as a picture.") + ".png" }

    private func saveImage() {
        guard let window, let data = png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Self.fileName
        panel.directoryURL = DownloadManager.folder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func shareImage() {
        guard let data = png else { return }
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        provider.suggestedName = Self.fileName
        let picker = NSSharingServicePicker(items: [provider])
        picker.delegate = sharing
        picker.show(relativeTo: content.share.bounds, of: content.share, preferredEdge: .minY)
    }

    #if DEBUG
    /// `card tilt <x> <y>|off`, `card save <path>`, `card shot <path>`, `card close`.
    func debug(_ f: [String]) {
        switch f.first ?? "" {
        case "tilt":
            let n = f.dropFirst().compactMap { Double($0) }
            content.stage.lean(toward: n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil)
        case "save": if f.count == 2 { try? png?.write(to: URL(fileURLWithPath: f[1])) }
        case "shot":
            guard f.count == 2, let number = window?.windowNumber else { break }
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", "\(number)", f[1]]
            try? shot.run()
        case "close": window?.close()
        default: break
        }
    }
    #endif
}

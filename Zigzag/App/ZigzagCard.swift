import AppKit
import CoreImage

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
        let date = Self.monthAndYear(start, locale: Words.dates)
        return String(localized: "Since \(date)", comment: "On Your Zigzag Card, under the name: the month and year Zigzag was first used on this Mac, as in Since November 2026.")
    }

    /// "November 2026", the month in the form a date uses ("ноября 2026 г.", not "ноябрь"), so it reads after "Since".
    static func monthAndYear(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        formatter.dateFormat = formatter.dateFormat.replacingOccurrences(of: "LLLL", with: "MMMM")
        return formatter.string(from: date)
    }

    /// Everything on it, for VoiceOver.
    var spoken: String { [name, sinceLine].filter { !$0.isEmpty }.joined(separator: "\n") }
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

// MARK: - Finishes

/// What the card is made of, picked under it in About and kept: the space's color, holographic foil, brushed
/// graphite, or linen paper.
enum CardFinish: String, CaseIterable {
    case space, holographic, graphite, paper

    /// The defaults it's kept in; a test's own keeps yours out of it.
    static var defaults: UserDefaults = .standard
    static let key = "CardFinish"

    static var chosen: CardFinish {
        get { defaults.string(forKey: key).flatMap(CardFinish.init(rawValue:)) ?? .space }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    var name: String {
        switch self {
        case .space: String(localized: "Space", comment: "Finish of Your Zigzag Card in About: the colors of the space you're in.")
        case .holographic: String(localized: "Holographic", comment: "Finish of Your Zigzag Card in About: iridescent foil.")
        case .graphite: String(localized: "Graphite", comment: "Finish of Your Zigzag Card in About: dark brushed metal.")
        case .paper: String(localized: "Paper", comment: "Finish of Your Zigzag Card in About: warm linen paper.")
        }
    }
}

/// The surface's grain, made at whatever size it's drawn so it's never a stretched bitmap.
enum CardTexture {
    /// Fine, even grain, as card stock has.
    case grain
    /// Long fine streaks running across, as brushed metal has.
    case brushed
    /// Threads both ways, as linen paper has.
    case linen

    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// A gray field around middle gray, `size` points at `scale` pixels per point, for an overlay.
    func image(size: CGSize, scale: CGFloat) -> CGImage? {
        let pixels = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let random = CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage.empty()
        // Noise with cells `w` by `h` pixels; `seed` takes another stretch of it so the layers don't line up.
        func field(_ w: CGFloat, _ h: CGFloat, seed: CGFloat, weight: CGFloat) -> CIImage {
            let v = CIVector(x: weight, y: 0, z: 0, w: 0)
            return random.transformed(by: CGAffineTransform(translationX: seed * 131, y: seed * 71))
                .transformed(by: CGAffineTransform(scaleX: w, y: h))
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": v, "inputGVector": v, "inputBVector": v,
                                                              "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                              "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        let pt = scale
        let parts: [CIImage]
        let strength: CGFloat
        switch self {
        case .grain:
            parts = [field(0.5 * pt, 0.5 * pt, seed: 1, weight: 0.5), field(1, 1, seed: 2, weight: 0.3), field(2 * pt, 2 * pt, seed: 3, weight: 0.2)]
            strength = 2.2
        case .brushed:
            parts = [field(70 * pt, 0.4 * pt, seed: 4, weight: 0.45), field(18 * pt, 0.2 * pt, seed: 5, weight: 0.35), field(1, 1, seed: 6, weight: 0.2)]
            strength = 2.6
        case .linen:
            parts = [field(3 * pt, 0.35 * pt, seed: 7, weight: 0.36), field(0.35 * pt, 3 * pt, seed: 8, weight: 0.36),
                     field(1, 1, seed: 9, weight: 0.2), field(12 * pt, 12 * pt, seed: 10, weight: 0.08)]
            strength = 2.4
        }
        var sum = parts[0]
        for part in parts.dropFirst() { sum = part.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum]) }
        // Stretched around middle gray, so the overlay neither lightens nor darkens on the whole.
        let k = strength, bias = 0.5 * (1 - strength)
        let out = sum.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)]).cropped(to: pixels)
        return Self.context.createCGImage(out, from: pixels, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

/// One finish's colors and materials, in light or dark: settled colors, never dynamic ones.
struct CardLook {
    var top: NSColor, bottom: NSColor
    /// The name, then "Since", each at least 4.5:1 on the face.
    var ink: NSColor, quiet: NSColor
    /// The wordmark's foil, edge to shine.
    var foil: [NSColor]
    var texture: CardTexture
    var grain: CGFloat
    /// The pressed zigzags' and the stamped wordmark's lit and shaded edges.
    var lit: CGFloat, shade: CGFloat
    var rim: CGFloat
    /// The iridescence, its strength and hues.
    var holo: CGFloat = 0
    var holoColors: [NSColor] = []
    var sheen: CGFloat
    /// A bright band across the face that follows the light.
    var band: CGFloat = 0
    var bandColor: NSColor = .white
    var shadow: Float

    static func of(_ finish: CardFinish, palette: CardPalette, dark: Bool) -> CardLook {
        let hex = Tokens.Color.hex
        switch finish {
        case .space:
            var c: [NSColor] = []
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                c = [palette.top, palette.bottom, palette.ink, palette.quiet].map { $0.usingColorSpace(.sRGB) ?? $0 }
            }
            let ink = c[2]
            let shine = ink.blended(withFraction: 0.18, of: dark ? .white : c[0]) ?? ink
            return CardLook(top: c[0], bottom: c[1], ink: ink, quiet: dark ? c[3].blended(withFraction: 0.45, of: ink) ?? c[3] : c[3], foil: [ink, shine, ink], texture: .grain, grain: 0.07,
                            lit: dark ? 0.07 : 0.6, shade: dark ? 0.3 : 0.08, rim: dark ? 0.16 : 0.7, sheen: dark ? 0.07 : 0.3,
                            band: dark ? 0.03 : 0.14, shadow: dark ? 0.5 : 0.16)
        case .holographic:
            // Soft hues three times round, so a few bands cross the card; at night only the cool half, as oil on dark
            // metal shows it.
            let hues: [CGFloat] = dark ? [0.48, 0.56, 0.66, 0.76, 0.86, 0.94] : [0.97, 0.07, 0.15, 0.36, 0.52, 0.64, 0.78]
            let ring = (hues + hues + hues + [hues[0]]).map {
                NSColor(calibratedHue: $0, saturation: dark ? 0.5 : 0.36, brightness: dark ? 0.9 : 1, alpha: 1).usingColorSpace(.sRGB)!
            }
            if dark {
                return CardLook(top: hex(0x20232B, 1), bottom: hex(0x121419, 1), ink: hex(0xF4F6FA, 1), quiet: hex(0xD5DAE2, 1),
                                foil: [hex(0xC9CFDA, 1), hex(0xFFFFFF, 1), hex(0xAEB6C3, 1)], texture: .grain, grain: 0.06,
                                lit: 0.08, shade: 0.3, rim: 0.2, holo: 0.18, holoColors: ring, sheen: 0.06, band: 0.06, shadow: 0.5)
            }
            return CardLook(top: hex(0xF3F4F7, 1), bottom: hex(0xD9DDE5, 1), ink: hex(0x1B2130, 1), quiet: hex(0x485166, 1),
                            foil: [hex(0x1B2130, 1), hex(0x46526A, 1), hex(0x1B2130, 1)], texture: .grain, grain: 0.05,
                            lit: 0.7, shade: 0.08, rim: 0.8, holo: 0.55, holoColors: ring, sheen: 0.35, band: 0.4, shadow: 0.18)
        case .graphite:
            return CardLook(top: hex(dark ? 0x3A3D43 : 0x43474D, 1), bottom: hex(dark ? 0x1C1D20 : 0x26282C, 1),
                            ink: hex(0xF5F6F8, 1), quiet: hex(0xD3D7DD, 1),
                            foil: [hex(0xB4BAC4, 1), hex(0xF7F9FC, 1), hex(0x9CA3AE, 1)], texture: .brushed, grain: 0.16,
                            lit: 0.08, shade: 0.38, rim: 0.22, sheen: 0.06, band: 0.08, bandColor: hex(0xD6E2F5, 1), shadow: dark ? 0.55 : 0.24)
        case .paper:
            return CardLook(top: hex(dark ? 0xE6DFD2 : 0xF7F2E8, 1), bottom: hex(dark ? 0xD8CFBF : 0xEBE3D3, 1),
                            ink: hex(0x2A2420, 1), quiet: hex(0x62584E, 1),
                            foil: [hex(0x7A4A2C, 1), hex(0xA66F48, 1), hex(0x6A3E23, 1)], texture: .linen, grain: 0.14,
                            lit: 0.75, shade: 0.09, rim: 0.8, sheen: 0.2, shadow: dark ? 0.45 : 0.14)
        }
    }

    /// The swatch under the card: its face in small.
    var swatch: [NSColor] { holo > 0 ? holoColors.map { $0.blended(withFraction: 1 - holo, of: top) ?? $0 } : [top, bottom] }
}

/// Where the light falls, from where the pointer is over the card: -1 to 1 each way from its middle, y up.
struct CardLight: Equatable {
    var point: CGPoint

    /// At rest, and in the saved picture: from the top left.
    static let rest = CardLight(point: CGPoint(x: -0.45, y: 0.55))

    /// The same light seen on the back, which faces the other way.
    var mirrored: CardLight { CardLight(point: CGPoint(x: -point.x, y: point.y)) }
    /// The sheen's middle in the card's unit square, y up, and its reach as a share of the width.
    var sheen: CGPoint { CGPoint(x: 0.5 + point.x * 0.6, y: 0.5 + point.y * 0.6) }
    static let sheenReach: CGFloat = 0.75
    /// The bright band's place along the diagonal, top left (0) to bottom right (1), and its half width.
    var band: CGFloat { 0.5 + (point.x - point.y) * 0.3 }
    static let bandWidth: CGFloat = 0.18
    /// The foil's middle, off the top left corner (unit square, y up), and the angle its hues start at, which turn
    /// as the card does.
    var holoCenter: CGPoint { CGPoint(x: -0.1 + point.x * 0.2, y: 1.25 + point.y * 0.15) }
    var holoAngle: CGFloat { -0.4 + point.x * 0.9 - point.y * 0.6 }
    /// How far the wordmark's shine has slid along it.
    var foilShift: CGFloat { point.x * 0.45 - point.y * 0.15 }
}

// MARK: - Drawing it

/// Draws the card for the window and the saved picture: the surface (color, grain, pressed zigzags, the lit edge),
/// the light on it (foil, sheen, the stamped wordmark) and the words. Nothing else goes on it.
enum CardArt {
    enum Side { case front, back }

    struct Parts: OptionSet {
        let rawValue: Int
        /// Color, grain, the pressed zigzags, the wordmark's stamped edge and the rim: what doesn't move.
        static let surface = Parts(rawValue: 1)
        /// The foil, the sheen, the band and the wordmark's shine, as `light` puts them.
        static let light = Parts(rawValue: 2)
        /// The name and "Since".
        static let words = Parts(rawValue: 4)
        static let all: Parts = [.surface, .light, .words]
    }

    static var size: CGSize { Tokens.Keepsake.size }

    /// The wordmark's place, top down: top left on the front, in the middle on the back.
    static func markRect(_ side: Side) -> CGRect {
        let k = Tokens.Keepsake.self
        switch side {
        case .front:
            let h = k.wordmarkHeight
            return CGRect(x: k.pad, y: k.pad, width: ceil(h * WordmarkView.aspect), height: h)
        case .back:
            let h = k.backWordmarkHeight, w = ceil(h * WordmarkView.aspect)
            return CGRect(x: round((size.width - w) / 2), y: round((size.height - h) / 2), width: w, height: h)
        }
    }

    /// The wordmark's outline in `rect`, top down.
    static func markPath(_ rect: CGRect) -> CGPath {
        var flip = CGAffineTransform(translationX: 0, y: rect.minY + rect.maxY).scaledBy(x: 1, y: -1)
        return WordmarkView.outline(in: rect).copy(using: &flip) ?? CGMutablePath()
    }

    static var nameFont: NSFont { Tokens.Font.voice(Tokens.Keepsake.nameSize) }
    static var sinceFont: NSFont { Tokens.Font.body() }

    /// Where the name and "Since" sit, top down.
    static func wordRects() -> (name: CGRect, since: CGRect) {
        let pad = Tokens.Keepsake.pad, width = size.width - pad * 2
        let since = sinceFont, name = nameFont
        let sinceBase = size.height - pad
        let nameBase = sinceBase - lineHeight(since) - Tokens.Space.x2
        return (CGRect(x: pad, y: nameBase - name.ascender, width: width, height: lineHeight(name)),
                CGRect(x: pad, y: sinceBase - since.ascender, width: width, height: lineHeight(since)))
    }

    /// One side as a picture `scale` pixels per point, with only `parts` drawn (the rest clear).
    static func image(_ face: CardFace, look: CardLook, side: Side = .front, light: CardLight = .rest, parts: Parts = .all,
                      scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Drawn top down, as text is laid out.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let rect = CGRect(origin: .zero, size: size)
        context.addPath(MaterialShape.rounded(rect, radius: Tokens.Keepsake.radius))
        context.clip()
        if parts.contains(.surface) { drawSurface(look, side: side, scale: scale, in: context) }
        if parts.contains(.light) { drawLight(look, side: side, light: side == .back ? light.mirrored : light, in: context) }
        if parts.contains(.words) {
            stampEdges(look, side: side, in: context)
            if side == .front { drawWords(face, look: look) }
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// The saved picture: the front at `Keepsake.exportScale`, lit from the top left, on its shadow with clear room
    /// around it, as PNG.
    static func png(_ face: CardFace, finish: CardFinish, palette: CardPalette, dark: Bool, scale: CGFloat = Tokens.Keepsake.exportScale) -> Data? {
        let look = CardLook.of(finish, palette: palette, dark: dark)
        guard let card = image(face, look: look, scale: scale) else { return nil }
        let k = Tokens.Keepsake.self, m = k.exportMargin
        let width = Int(((size.width + m * 2) * scale).rounded()), height = Int(((size.height + m * 2) * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let frame = CGRect(x: m, y: m, width: size.width, height: size.height)
        // Shadows only: the shape is drawn far off the canvas and its shadow thrown back under the card.
        let away = size.width + m * 4
        let shape = MaterialShape.rounded(frame.offsetBy(dx: away, dy: 0), radius: k.radius)
        for (radius, drop, opacity) in [(k.ambientRadius, k.ambientDrop, CGFloat(0.22)), (k.contactRadius, k.contactDrop, CGFloat(0.16))] {
            context.saveGState()
            context.setShadow(offset: CGSize(width: -away * scale, height: -drop * scale), blur: radius * scale,
                              color: NSColor.black.withAlphaComponent(opacity).cgColor)
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
        }
        context.interpolationQuality = .none
        context.draw(card, in: frame)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        // 144 dpi, so it opens at a Retina screen's size.
        rep.size = NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Layers

    private static func drawSurface(_ look: CardLook, side: Side, scale: CGFloat, in context: CGContext) {
        let rect = CGRect(origin: .zero, size: size)
        if let gradient = gradient([look.top, look.bottom]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if look.grain > 0, let texture = look.texture.image(size: size, scale: scale) {
            context.saveGState()
            context.setBlendMode(.overlay)
            context.setAlpha(look.grain)
            context.draw(texture, in: rect)
            context.restoreGState()
        }
        drawMotif(look, side: side, in: context)
        // The edge catches the light, more along the top.
        context.saveGState()
        let r = Tokens.Keepsake.radius
        context.addPath(MaterialShape.rounded(rect.insetBy(dx: 0.5, dy: 0.5), radius: r - 0.5))
        context.setLineWidth(1)
        context.replacePathWithStrokedPath()
        context.clip()
        if let rim = gradient([NSColor.white.withAlphaComponent(look.rim), NSColor.white.withAlphaComponent(look.rim * 0.2)]) {
            context.drawLinearGradient(rim, start: CGPoint(x: rect.midX, y: 0), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        context.restoreGState()
    }

    /// Small ribbon Zs pressed into the surface in a half-drop grid, a shaded top edge and a lit bottom one, fading
    /// toward the words.
    private static func drawMotif(_ look: CardLook, side: Side, in context: CGContext) {
        let k = Tokens.Keepsake.self
        let h = k.motifHeight, w = h * Brand.aspect
        let one = Brand.path(Brand.centerline(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)).map { CGPoint(x: $0.x, y: -$0.y) })
            .copy(strokingWithWidth: h * 0.17, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
        let all = CGMutablePath()
        var row = 0
        var y = -k.motifStep.height
        while y < size.height + k.motifStep.height {
            var x = (row % 2 == 0 ? 0 : k.motifStep.width / 2) - k.motifStep.width
            while x < size.width + k.motifStep.width {
                all.addPath(one, transform: CGAffineTransform(translationX: x, y: y))
                x += k.motifStep.width
            }
            y += k.motifStep.height
            row += 1
        }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        deboss(all, depth: k.motifDepth, look: look, in: context)
        // Strong at the far side, faint under the words and the wordmark.
        context.setBlendMode(.destinationIn)
        let fade = side == .front ? [NSColor.black.withAlphaComponent(0.3), NSColor.black] : [NSColor.black.withAlphaComponent(0.7), NSColor.black]
        if let mask = gradient(fade) {
            context.drawLinearGradient(mask, start: CGPoint(x: size.width * 0.15, y: size.height), end: CGPoint(x: size.width, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Inside `path`, top down: a shaded edge along the top and a lit one along the bottom, as a shape pressed in.
    private static func deboss(_ path: CGPath, depth: CGFloat, look: CardLook, strength: CGFloat = 1, in context: CGContext) {
        let outside = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        for (dy, color) in [(depth, NSColor.black.withAlphaComponent(look.shade * strength)), (-depth, NSColor.white.withAlphaComponent(look.lit * strength))] {
            context.saveGState()
            context.addPath(path)
            context.clip()
            let rest = CGMutablePath()
            rest.addRect(outside)
            rest.addPath(path, transform: CGAffineTransform(translationX: 0, y: dy))
            context.addPath(rest)
            context.setFillColor(color.cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
    }

    private static func drawLight(_ look: CardLook, side: Side, light: CardLight, in context: CGContext) {
        let rect = CGRect(origin: .zero, size: size)
        if look.holo > 0 {
            let c = light.holoCenter, a = light.holoAngle
            context.saveGState()
            context.setAlpha(look.holo)
            // One layer, so the wedges overlap without seams and fade as one.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            // The angle as the window's layer reads it, in points and y up.
            conic(look.holoColors, center: CGPoint(x: c.x * rect.width, y: (1 - c.y) * rect.height),
                  angle: atan2(sin(a) * rect.height, cos(a) * rect.width), in: context)
            context.endTransparencyLayer()
            context.restoreGState()
        }
        let s = light.sheen
        if let sheen = gradient([NSColor.white.withAlphaComponent(look.sheen), NSColor.white.withAlphaComponent(0)]) {
            let center = CGPoint(x: s.x * rect.width, y: (1 - s.y) * rect.height)
            context.drawRadialGradient(sheen, startCenter: center, startRadius: 0, endCenter: center, endRadius: rect.width * CardLight.sheenReach, options: [])
        }
        if look.band > 0 {
            let b = light.band, w = CardLight.bandWidth
            let colors = [look.bandColor.withAlphaComponent(0), look.bandColor.withAlphaComponent(look.band), look.bandColor.withAlphaComponent(0)]
            if let band = gradient(colors, at: [b - w, b, b + w]) {
                context.drawLinearGradient(band, start: .zero, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
            }
        }
        drawFoil(look, side: side, light: light, in: context)
    }

    /// Which way round the window's conic gradient runs, as seen: 1 counterclockwise, -1 clockwise.
    static let conicTurn: CGFloat = 1

    /// A conic gradient as thin wedges, from `angle` (as seen, y up) round the way the window's layer runs, top down.
    private static func conic(_ colors: [NSColor], center: CGPoint, angle: CGFloat, in context: CGContext) {
        let stops = colors.map { $0.usingColorSpace(.sRGB) ?? $0 }
        guard stops.count > 1 else { return }
        let reach = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? 0
        let steps = 1440
        context.saveGState()
        context.setShouldAntialias(false)
        for i in 0..<steps {
            let t = (CGFloat(i) + 0.5) / CGFloat(steps)
            let at = t * CGFloat(stops.count - 1)
            let j = min(Int(at), stops.count - 2), f = at - CGFloat(j)
            let color = stops[j].blended(withFraction: f, of: stops[j + 1]) ?? stops[j]
            let a0 = angle + conicTurn * 2 * .pi * CGFloat(i) / CGFloat(steps)
            let a1 = angle + conicTurn * 2 * .pi * (CGFloat(i) + 1.6) / CGFloat(steps)
            let wedge = CGMutablePath()
            wedge.move(to: center)
            // Top down, so an angle seen counterclockwise has y going up the page.
            wedge.addLine(to: CGPoint(x: center.x + cos(a0) * reach, y: center.y - sin(a0) * reach))
            wedge.addLine(to: CGPoint(x: center.x + cos(a1) * reach, y: center.y - sin(a1) * reach))
            wedge.closeSubpath()
            context.addPath(wedge)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        context.restoreGState()
    }

    /// The wordmark in foil: its shine slides along it with the light.
    private static func drawFoil(_ look: CardLook, side: Side, light: CardLight, in context: CGContext) {
        let mark = markRect(side)
        let (start, end, locations) = foilAxis(light)
        context.saveGState()
        context.addPath(markPath(mark))
        context.clip()
        if let gradient = gradient(foilColors(look), at: locations) {
            context.drawLinearGradient(gradient, start: CGPoint(x: mark.minX + start.x * mark.width, y: mark.minY + (1 - start.y) * mark.height),
                                       end: CGPoint(x: mark.minX + end.x * mark.width, y: mark.minY + (1 - end.y) * mark.height),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    /// The foil's run across the wordmark's box (unit square, y up) and its stops.
    static func foilAxis(_ light: CardLight) -> (start: CGPoint, end: CGPoint, locations: [CGFloat]) {
        let s = light.foilShift
        return (CGPoint(x: -0.4 + s, y: 1), CGPoint(x: 1.4 + s, y: 0), [0, 0.38, 0.5, 0.62, 1])
    }

    static func foilColors(_ look: CardLook) -> [NSColor] { [look.foil[0], look.foil[0], look.foil[1], look.foil[2], look.foil[2]] }

    /// The wordmark's pressed edges, over its foil.
    private static func stampEdges(_ look: CardLook, side: Side, in context: CGContext) {
        deboss(markPath(markRect(side)), depth: Tokens.Keepsake.stampDepth, look: look, strength: 0.4, in: context)
    }

    private static func drawWords(_ face: CardFace, look: CardLook) {
        let rects = wordRects()
        let since = NSMutableParagraphStyle()
        since.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: face.sinceLine, attributes: [.font: sinceFont, .foregroundColor: look.quiet, .paragraphStyle: since])
            .draw(with: rects.since, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if !face.name.isEmpty {
            Tokens.Font.voiceText(face.name, size: Tokens.Keepsake.nameSize, color: look.ink, paragraph: since)
                .draw(with: rects.name, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    static func gradient(_ colors: [NSColor], at locations: [CGFloat]? = nil) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map { ($0.usingColorSpace(.sRGB) ?? $0).cgColor } as CFArray,
                   locations: locations)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
}

// MARK: - The card on screen

/// One side of the card as layers: its surface as a picture, then the foil, the wordmark's shine and the sheen as
/// layers of their own so they move with the light, then the words.
private final class CardSide {
    let side: CardArt.Side
    let layer = CALayer()
    private let holo = CAGradientLayer()
    private let foil = CAGradientLayer()
    private let foilShape = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private let band = CAGradientLayer()
    private let words = CALayer()

    init(_ side: CardArt.Side) {
        self.side = side
        let size = CardArt.size
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.cornerRadius = Tokens.Keepsake.radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.contentsGravity = .resize
        layer.isDoubleSided = false
        holo.type = .conic
        holo.frame = layer.bounds
        sheen.type = .radial
        sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 1)
        let reach = size.width * CardLight.sheenReach
        sheen.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
        band.frame = layer.bounds
        band.startPoint = CGPoint(x: 0, y: 1)
        band.endPoint = CGPoint(x: 1, y: 0)
        let mark = CardArt.markRect(side)
        // The mark's box y up, as this layer has it.
        foil.frame = CGRect(x: mark.minX, y: size.height - mark.maxY, width: mark.width, height: mark.height)
        foilShape.path = WordmarkView.outline(in: foil.bounds)
        foil.mask = foilShape
        words.frame = layer.bounds
        words.contentsGravity = .resize
        [holo, sheen, band, foil, words].forEach { layer.addSublayer($0) }
    }

    func draw(_ face: CardFace, look: CardLook, scale: CGFloat) {
        layer.contents = CardArt.image(face, look: look, side: side, parts: .surface, scale: scale)
        words.contents = CardArt.image(face, look: look, side: side, parts: .words, scale: scale)
        layer.contentsScale = scale
        words.contentsScale = scale
        holo.isHidden = look.holo == 0
        holo.colors = look.holoColors.map(\.cgColor)
        holo.opacity = Float(look.holo)
        foil.colors = CardArt.foilColors(look).map(\.cgColor)
        foil.locations = CardArt.foilAxis(.rest).locations.map { NSNumber(value: Double($0)) }
        sheen.colors = [NSColor.white.withAlphaComponent(look.sheen).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        band.isHidden = look.band == 0
        band.colors = [look.bandColor.withAlphaComponent(0), look.bandColor.withAlphaComponent(look.band), look.bandColor.withAlphaComponent(0)].map(\.cgColor)
    }

    /// The light where `light` says, each change through `set`, which animates it or not.
    func light(_ light: CardLight, set: (CALayer, String, Any) -> Void) {
        let light = side == .back ? light.mirrored : light
        let size = CardArt.size
        let c = light.holoCenter, a = light.holoAngle
        set(holo, "startPoint", NSValue(point: c))
        set(holo, "endPoint", NSValue(point: CGPoint(x: c.x + cos(a) * 0.1, y: c.y + sin(a) * 0.1)))
        let axis = CardArt.foilAxis(light)
        set(foil, "startPoint", NSValue(point: axis.start))
        set(foil, "endPoint", NSValue(point: axis.end))
        set(sheen, "position", NSValue(point: CGPoint(x: light.sheen.x * size.width, y: light.sheen.y * size.height)))
        let b = light.band, w = CardLight.bandWidth
        set(band, "locations", [b - w, b, b + w].map { NSNumber(value: Double($0)) })
    }
}

/// The card as an object: it floats on two soft shadows, turns up to `Keepsake.tilt` degrees toward the pointer
/// with its foil and sheen following, and settles back when the pointer goes. A click turns it over. With Reduce
/// Motion it holds still, the light at rest, and turning over is a crossfade.
final class CardStage: NSView {
    /// Flat, so the turning card is drawn into its plane and never dips behind the shadows beside it; it gives the
    /// card its perspective.
    private let holder = CALayer()
    private let card = CATransformLayer()
    private let flipper = CATransformLayer()
    private let front = CardSide(.front)
    private let back = CardSide(.back)
    private let ambient = CALayer()
    private let contact = CALayer()
    var face: CardFace { didSet { if face != oldValue { redraw() } } }
    var palette: CardPalette { didSet { if palette != oldValue { redraw() } } }
    var finish: CardFinish { didSet { if finish != oldValue { redraw(fade: true) } } }
    /// Where the pointer is over the card, -1 to 1 from its middle (y up); nil at rest.
    private(set) var lean: CGPoint?
    /// Whether its back is showing.
    private(set) var showsBack = false

    init(face: CardFace, palette: CardPalette, finish: CardFinish) {
        self.face = face
        self.palette = palette
        self.finish = finish
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = false
        for shadow in [ambient, contact] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOffset = .zero
            layer?.addSublayer(shadow)
        }
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / Tokens.Keepsake.perspective
        holder.sublayerTransform = perspective
        back.layer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        flipper.addSublayer(front.layer)
        flipper.addSublayer(back.layer)
        card.addSublayer(flipper)
        holder.addSublayer(card)
        layer?.addSublayer(holder)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Your Zigzag Card", comment: "VoiceOver name of Your Zigzag Card in About Zigzag."))
        redraw()
        Tokens.Motion.withoutAnimation { applyLight(nil, settling: false, animated: false) }
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

    /// The card's place in this view.
    var cardFrame: CGRect {
        let size = CardArt.size
        return CGRect(x: round((bounds.width - size.width) / 2), y: round((bounds.height - size.height) / 2), width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let frame = cardFrame
        Tokens.Motion.withoutAnimation {
            holder.frame = bounds
            // The perspective's eye straight over the card's middle.
            holder.anchorPoint = CGPoint(x: frame.midX / max(bounds.width, 1), y: frame.midY / max(bounds.height, 1))
            holder.frame = bounds
            card.bounds = CGRect(origin: .zero, size: frame.size)
            card.position = CGPoint(x: frame.midX, y: frame.midY)
            flipper.bounds = card.bounds
            flipper.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
            for side in [front, back] { side.layer.position = CGPoint(x: frame.width / 2, y: frame.height / 2) }
            let path = MaterialShape.rounded(frame, radius: Tokens.Keepsake.radius)
            for (shadow, drop) in [(ambient, Tokens.Keepsake.ambientDrop), (contact, Tokens.Keepsake.contactDrop)] {
                shadow.frame = bounds
                shadow.shadowPath = path.copy(using: [CGAffineTransform(translationX: 0, y: -drop)])
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return cardFrame.contains(convert(point, from: superview)) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if cardFrame.contains(convert(event.locationInWindow, from: nil)) { turnOver() }
    }

    override func accessibilityPerformPress() -> Bool {
        turnOver()
        return true
    }

    private var look: CardLook { CardLook.of(finish, palette: palette, dark: effectiveAppearance.isDark) }

    private func redraw(fade: Bool = false) {
        let look = look
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(!fade)
        CATransaction.setAnimationDuration(Tokens.Motion.state)
        CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
        front.draw(face, look: look, scale: scale)
        back.draw(face, look: look, scale: scale)
        ambient.shadowRadius = Tokens.Keepsake.ambientRadius
        ambient.shadowOpacity = look.shadow
        contact.shadowRadius = Tokens.Keepsake.contactRadius
        contact.shadowOpacity = look.shadow * 0.9
        CATransaction.commit()
        setAccessibilityValue(face.spoken)
    }

    /// Turns toward `point` (-1 to 1 each way from the card's middle, y up), or settles back with nil.
    func lean(toward point: CGPoint?) {
        let point = point.map { CGPoint(x: min(max($0.x, -1), 1), y: min(max($0.y, -1), 1)) }
        let settling = point == nil
        guard point != lean || settling != (lean == nil) else { return }
        lean = point
        applyLight(point, settling: settling, animated: !Tokens.Motion.reduceMotion)
    }

    private func applyLight(_ point: CGPoint?, settling: Bool, animated: Bool) {
        let still = Tokens.Motion.reduceMotion
        let light = still ? .rest : point.map(CardLight.init(point:)) ?? .rest
        var transform = CATransform3DIdentity
        if let point, !still {
            let most = Tokens.Keepsake.tilt * .pi / 180
            // Its face turns to the pointer: the side nearest it goes back.
            transform = CATransform3DRotate(transform, point.x * most, 0, 1, 0)
            transform = CATransform3DRotate(transform, -point.y * most, 1, 0, 0)
        }
        let set: (CALayer, String, Any) -> Void = { layer, key, value in
            let from = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            Tokens.Motion.withoutAnimation { layer.setValue(value, forKeyPath: key) }
            guard animated else { return }
            let move: CABasicAnimation
            if settling {
                // Back to rest on a soft spring that barely overshoots.
                let spring = CASpringAnimation(perceptualDuration: Tokens.Keepsake.settle, bounce: Tokens.Keepsake.settleBounce)
                spring.duration = spring.settlingDuration * Tokens.Motion.debugSlowdown
                move = spring
                move.keyPath = key
            } else {
                move = Tokens.Motion.easeAnimation(keyPath: key, duration: Tokens.Keepsake.follow)
            }
            move.fromValue = from
            move.toValue = value
            layer.add(move, forKey: key)
        }
        set(card, "transform", NSValue(caTransform3D: transform))
        front.light(light, set: set)
        back.light(light, set: set)
    }

    /// Shows the other side: turned over about its upright middle, or crossfaded with Reduce Motion.
    func turnOver() {
        showsBack.toggle()
        let turned = CATransform3DMakeRotation(showsBack ? .pi : 0, 0, 1, 0)
        if Tokens.Motion.reduceMotion {
            Tokens.Motion.withoutAnimation {
                flipper.transform = CATransform3DIdentity
                back.layer.transform = CATransform3DIdentity
                back.layer.isDoubleSided = true
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(Tokens.Motion.crossfade)
            CATransaction.setAnimationTimingFunction(Tokens.Motion.easeOut)
            front.layer.opacity = showsBack ? 0 : 1
            back.layer.opacity = showsBack ? 1 : 0
            CATransaction.commit()
            return
        }
        Tokens.Motion.withoutAnimation {
            back.layer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            back.layer.isDoubleSided = false
            front.layer.opacity = 1
            back.layer.opacity = 1
        }
        let from = flipper.presentation()?.value(forKeyPath: "transform.rotation.y") as? CGFloat ?? (showsBack ? 0 : .pi)
        Tokens.Motion.withoutAnimation { flipper.transform = turned }
        let move = Tokens.Motion.easeAnimation(keyPath: "transform.rotation.y", duration: Tokens.Keepsake.turn, timing: Tokens.Motion.drawer)
        move.fromValue = from
        move.toValue = showsBack ? CGFloat.pi : 0
        flipper.add(move, forKey: "turn")
    }

    /// Where a point in this view sits over the card, -1 to 1 each way from its middle.
    func leanPoint(for location: NSPoint) -> CGPoint {
        let frame = cardFrame
        return CGPoint(x: (location.x - frame.midX) / (frame.width / 2), y: (location.y - frame.midY) / (frame.height / 2))
    }
}

// MARK: - Picking a finish

/// The finishes as a row of round swatches under the card, as the space editor's: a faint ring under the pointer,
/// a fine ring around the chosen one.
final class CardFinishSwatches: NSView {
    var onPick: ((CardFinish) -> Void)?
    var selected: CardFinish { didSet { tiles.forEach { $0.isSelected = $0.finish == selected } } }
    var palette: CardPalette { didSet { tiles.forEach { $0.palette = palette } } }
    private var tiles: [CardFinishSwatch] = []
    private static let side: CGFloat = Tokens.Metric.controlHeight, gap = Tokens.Space.x2

    init(selected: CardFinish, palette: CardPalette) {
        self.selected = selected
        self.palette = palette
        super.init(frame: .zero)
        for finish in CardFinish.allCases {
            let tile = CardFinishSwatch(finish: finish, palette: palette)
            tile.isSelected = finish == selected
            tile.onClick = { [weak self] _ in
                self?.selected = finish
                self?.onPick?(finish)
            }
            addSubview(tile)
            tiles.append(tile)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(String(localized: "Finish", comment: "VoiceOver name of the row of finishes under Your Zigzag Card in About Zigzag."))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    #if DEBUG
    func debugHover(_ index: Int?) { for (i, tile) in tiles.enumerated() { tile.isHovered = i == index } }
    #endif

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side * CGFloat(tiles.count) + Self.gap * CGFloat(tiles.count - 1), height: Self.side)
    }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func accessibilityChildren() -> [Any]? { tiles }

    override func layout() {
        super.layout()
        for (i, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: CGFloat(i) * (Self.side + Self.gap), y: (bounds.height - Self.side) / 2, width: Self.side, height: Self.side)
        }
    }
}

/// One finish, round: its surface in small.
private final class CardFinishSwatch: InteractiveView {
    let finish: CardFinish
    var palette: CardPalette { didSet { stateDidChange(animated: false) } }
    private let ring = CALayer()
    private let fill = CAGradientLayer()

    init(finish: CardFinish, palette: CardPalette) {
        self.finish = finish
        self.palette = palette
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(ring)
        layer?.addSublayer(fill)
        fill.masksToBounds = true
        toolTip = finish.name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(finish.name)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }

    override func layout() {
        super.layout()
        stateDidChange(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stateDidChange(animated: false)
    }

    override func stateDidChange(animated: Bool) {
        let look = CardLook.of(finish, palette: palette, dark: effectiveAppearance.isDark)
        Tokens.Motion.withoutAnimation {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                // Chosen, an accent ring with a gap, as Reader's colors; under the pointer a faint ring, nothing moving.
                SwatchRing.draw(ring: ring, fill: fill, in: bounds, selected: isSelected, hovered: isHovered, chosen: Tokens.Color.accent)
                fill.type = look.holo > 0 ? .conic : .axial
                fill.colors = look.swatch.map(\.cgColor)
                fill.startPoint = look.holo > 0 ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: 0.2, y: 0.9)
                fill.endPoint = look.holo > 0 ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 0.8, y: 0.1)
            }
        }
        setAccessibilityValue(NSNumber(value: isSelected ? 1 : 0))
    }
}

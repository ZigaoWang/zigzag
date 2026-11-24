import AppKit

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    /// Drawn instead of its site's icon: an SF Symbol's name, or an emoji. Nil: its site's (and older libraries).
    var icon: String? = nil

    /// Chosen icon, else the site's set icon (`SiteIcons`), else its favicon.
    var displayIcon: NSImage? { (icon ?? SiteIcons.icon(for: url)).map(IconChoice.pageIcon) ?? FaviconStore.shared.cachedIcon(for: url) }
}

/// A named group of a space's pinned pages, folded open or shut in the sidebar. Its pages stay in the space's own list
/// (kept next to each other, its subfolders' with them); the folder only says which ones it holds directly.
struct BookmarkFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bookmarkIDs: [UUID] = []
    var isOpen = true
    /// Drawn inside the folder: an SF Symbol's name, or an emoji. Nil: a plain folder.
    var icon: String? = nil
    /// The folder this one is inside. Nil: it sits among the space's pinned pages.
    var parentID: UUID? = nil
    /// The pages that were open when it was shut: shut on purpose, it hides them too (#154), though pages opened
    /// after still show under it (#94). Nil while it's open.
    var tucked: [UUID]? = nil
    /// The tab group (#209) this folder was pinned from; nil if made by hand.
    var groupID: UUID? = nil
}

extension Array where Element == BookmarkFolder {
    /// The folders directly inside `parent` (nil: the top level).
    nonisolated func children(of parent: UUID?) -> [BookmarkFolder] { filter { $0.parentID == parent } }

    /// Every folder inside `id`, at any depth.
    nonisolated func descendants(of id: UUID) -> [UUID] {
        // The folders in each one, looked up once: a big imported tree has hundreds.
        let inside = Dictionary(grouping: filter { $0.parentID != nil }, by: { $0.parentID! })
        var result: [UUID] = [], seen: Set<UUID> = [id], queue = [id]
        while let next = queue.popLast() {
            for child in inside[next] ?? [] where seen.insert(child.id).inserted { result.append(child.id); queue.append(child.id) }
        }
        return result
    }

    /// Every pinned page in a folder or its subfolders.
    nonisolated func pages(in id: UUID) -> Set<UUID> {
        let all = Set(descendants(of: id) + [id])
        var ids: Set<UUID> = []
        for folder in self where all.contains(folder.id) { ids.formUnion(folder.bookmarkIDs) }
        return ids
    }

    /// Pinned pages in a folder and its subfolders, in list order.
    nonisolated func pages(in id: UUID, ordered order: [UUID]) -> [UUID] {
        let inside = pages(in: id)
        return order.filter { inside.contains($0) }
    }

    /// Whether the folder or any subfolder is open (or shut, for `open` false).
    nonisolated func anyInTree(of id: UUID, isOpen open: Bool) -> Bool {
        let tree = Set(descendants(of: id) + [id])
        return contains { tree.contains($0.id) && $0.isOpen == open }
    }

    /// Opens or shuts a folder and all its subfolders; shutting hides their pages in `shown`.
    nonisolated func folding(_ id: UUID, open: Bool, shown: Set<UUID> = []) -> [BookmarkFolder] {
        folding(Set(descendants(of: id) + [id]), open: open, shown: shown)
    }

    /// Opens or shuts these folders; shutting hides their pages in `shown`.
    nonisolated func folding(_ tree: Set<UUID>, open: Bool, shown: Set<UUID> = []) -> [BookmarkFolder] {
        map { folder in
            guard tree.contains(folder.id) else { return folder }
            var folder = folder
            let tucking = open || shown.isEmpty ? [] : pages(in: folder.id).intersection(shown)
            folder.isOpen = open
            folder.tucked = tucking.isEmpty ? nil : tucking.sorted { $0.uuidString < $1.uuidString }
            return folder
        }
    }

    /// The folders with a pinned page in them or in a folder inside them.
    nonisolated var holdingPages: Set<UUID> {
        let parent = Dictionary(map { ($0.id, $0.parentID) }, uniquingKeysWith: { a, _ in a })
        var result: Set<UUID> = []
        for folder in self where !folder.bookmarkIDs.isEmpty {
            var next: UUID? = folder.id
            while let id = next, result.insert(id).inserted { next = parent[id] ?? nil }
        }
        return result
    }

    /// How many folders a folder is inside (0 at the top level).
    nonisolated func depth(of id: UUID) -> Int {
        var depth = 0, seen: Set<UUID> = [id]
        var parent = first { $0.id == id }?.parentID
        while let p = parent, seen.insert(p).inserted { depth += 1; parent = first { $0.id == p }?.parentID }
        return depth
    }
}

/// Pinned pages that open side by side, as the split view or tile group (#160, #203) they were pinned from: two
/// halves, or three or four pages in their places. Its pages stay in the space's own list in its order (the group's
/// reading order), one right after another, in the same folder; its first page's row (or tile) carries the rest.
///
/// It is the split a window keeps on screen (`TabManager.SplitPair`) with the pinned pages' ids in it: one model, one
/// layout and one reading of what's saved, for two pages or four.
nonisolated struct PinnedSplit: Codable, Sendable {
    /// Its pages, by their pinned ids, and how they're laid out.
    var layout: TabManager.SplitPair

    init(left: UUID, right: UUID) {
        layout = TabManager.SplitPair(left: left, right: right)
    }

    init(layout: TabManager.SplitPair) {
        self.layout = layout
    }

    /// Pages `ids` (in `pair`'s order) laid out as `pair` lays out its own; nil when the two don't match.
    init?(_ ids: [UUID], as pair: TabManager.SplitPair) {
        guard let layout = pair.withPages(ids) else { return nil }
        self.layout = layout
    }

    /// Read as a split on screen is: a two-page record of any age as it always was, a group whose pages or places
    /// don't add up as the split of its first two.
    init(from decoder: Decoder) throws {
        layout = try TabManager.SplitPair(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(left, forKey: .left)
        try c.encode(right, forKey: .right)
        try c.encode(ratio, forKey: .ratio)
        try c.encode(vertical, forKey: .vertical)
        // Two pages are written as they always were.
        if isGroup {
            try c.encode(more, forKey: .more)
            try c.encode(regions, forKey: .regions)
            try c.encode(otherRatio, forKey: .otherRatio)
            try c.encodeIfPresent(shares, forKey: .shares)
        }
    }

    private enum CodingKeys: String, CodingKey { case left, right, ratio, vertical, more, regions, otherRatio, shares }

    var left: UUID { get { layout.left } set { layout.left = newValue } }
    var right: UUID { get { layout.right } set { layout.right = newValue } }
    var ratio: Double { get { layout.ratio } set { layout.ratio = newValue } }
    var vertical: Bool { get { layout.vertical } set { layout.vertical = newValue } }
    var more: [UUID] { layout.more }
    var regions: [TileRegion]? { layout.regions }
    var otherRatio: Double { layout.otherRatio }
    var shares: [Double]? { layout.shares }
    /// How its pages share the page area: the same shape the group had on screen.
    var shape: TileShape { layout.shape }

    /// Its pages, in order.
    var ids: [UUID] { layout.ids }
    /// The pages that ride in the first one's row or tile.
    var riders: ArraySlice<UUID> { ids.dropFirst() }
    /// Three or four pages, not a split of two.
    var isGroup: Bool { layout.isGroup }
    func contains(_ id: UUID) -> Bool { layout.contains(id) }

    /// How it opens: tabs `tabIDs` (one for each of its pages, in its order) side by side as it was laid out.
    func pair(of tabIDs: [UUID]) -> TabManager.SplitPair? { layout.withPages(tabIDs) }
}

/// The same pinned split keeps the same pages in the same order. Its size and direction are left out, so resizing it
/// doesn't count as changing the library, and ⌘Z for what came before still works.
extension PinnedSplit: Equatable {
    static func == (a: PinnedSplit, b: PinnedSplit) -> Bool { a.ids == b.ids }
}

struct SpaceInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: SpaceColor
    var bookmarks: [Bookmark] = []
    /// Folders of pinned pages. Nil: none yet (older libraries).
    var folders: [BookmarkFolder]? = nil
    /// Pinned pages kept together as split views. Nil: none (older libraries too).
    var pinnedSplits: [PinnedSplit]? = nil
    /// A custom tint picked on the hue slider (0…1). Overrides `color` when set.
    var hue: Double? = nil
    /// How strong a custom tint is (0 = barely there, 1 = rich). Only used with `hue`.
    var intensity: Double? = nil
    /// "light" or "dark" to force the window's appearance in this space; nil follows the system.
    var appearance: String? = nil
    /// How much grain the window's frame has in this space (0 = smooth, 1 = most). Nil: smooth.
    var grain: Double? = nil
    /// A second hue the frame fades into. Nil: one color.
    var hue2: Double? = nil
    /// How strong the second color is; nil: the same as the first.
    var intensity2: Double? = nil
    /// Which way the gradient runs, in degrees (0: left to right, 90: top to bottom). Nil: 45, top left to bottom right.
    var angle: Double? = nil
    /// Saved before 0.4, when see-through was a look of its own, washed white to black. Read once by `upgraded`,
    /// which turns it into `translucency`; never set now.
    var glass: Bool? = nil
    /// How light or dark the space is, from 0 (lightest) to 1 (darkest); the window's mode follows it.
    /// Nil: automatic, light by day and dark at night with the system.
    var brightness: Double? = nil
    /// The second color's own brightness; nil: the same as the first.
    var brightness2: Double? = nil
    /// A palette color following the Mac: its depth by day and at night, both ends of a gradient alike. Nil: the
    /// strength in `intensity` instead. Only used without `brightness`.
    var dayDepth: Double? = nil
    var nightDepth: Double? = nil
    /// How much of its hue the color has, from 0 (none: white, a gray or black) to 1 (all of it). Nil: all.
    var tint: Double? = nil
    /// The second color's own tint. Nil: all of it.
    var tint2: Double? = nil
    /// How much of the desktop shows through the frame, from 0 (solid) to 1 (the most). Nil: solid.
    var translucency: Double? = nil
    /// False: frosted glass, milkier and softer. Nil or true: clear glass where the Mac has it (`usesClearGlass`).
    var clearGlass: Bool? = nil
    /// A palette look's glass: the color tints it as it is, never leaning toward its dot, so the desktop shows through
    /// clear instead of under a grayed veil; a deep one covers a little more (`Tokens.Frame.clearNightCover`). Nil: as
    /// any other see-through space.
    var clearTint: Bool? = nil
    /// Which texture the grain is: "linen" (`MaterialImages.linen`). Nil: fine film grain.
    var texture: String? = nil
    /// Whether this Mac has clear glass (Liquid Glass, macOS 26 and later).
    static var hasClearGlass: Bool { if #available(macOS 26.0, *) { true } else { false } }
    /// Clear glass, the default where the Mac has it; frosted when chosen, or before macOS 26.
    var usesClearGlass: Bool { Self.hasClearGlass && clearGlass != false && !PowerSaving.isOn }
    /// Shown beside its name and in the space switcher: an SF Symbol's name, or an emoji. Nil: a dot.
    var icon: String? = nil
    /// The browser profile this space was made for by an import (`ImportBatch.BrowserProfile.key`), so importing that
    /// profile again adds to it instead of making another. Nil: made here.
    var importedFrom: String? = nil
    /// The color Zigzag gave the space when it was made, which Use Default Colors puts back. Nil: not kept yet (made
    /// before it was, and not changed since), so `Library.defaultColors` works it out.
    var defaultColor: SpaceColor? = nil
    /// Hosts without "www." that always open in this space, subdomains included (#286, `SiteRoutes`).
    var routedSites: [String]? = nil
    /// Background file name in `Backgrounds` (`SpaceBackground`); nil uses the space's color.
    var backgroundImage: String? = nil

    /// No hue of its own: white, a gray, or black.
    var isNeutral: Bool { (hue == nil && color.isNeutral) || (tint ?? 1) < 0.005 }
    /// How much of its hue the first color has, 0 for white, grays and black; past 1 for the palette's lively colors.
    var tintAmount: Double { isNeutral ? 0 : min(max(tint ?? 1, 0), SpaceColor.maxTint) }
    var tintAmount2: Double { min(max(tint2 ?? 1, 0), SpaceColor.maxTint) }
    /// Following the Mac between a palette color's own depths.
    private var followsDepths: (day: Double, night: Double)? {
        guard brightness == nil, !isNeutral, let dayDepth, let nightDepth else { return nil }
        return (dayDepth, nightDepth)
    }

    /// How much of the desktop shows through, 0 when solid.
    var seeThrough: Double { min(max(translucency ?? 0, 0), 1) }
    var isSeeThrough: Bool { seeThrough > 0.005 }
    /// How much the space's color covers the frosted desktop behind a see-through frame. It thins as more shows but
    /// never below a half, so the space keeps its color all the way up.
    /// Clear glass lets more of the blurred desktop through: the color thins further, to about a third at the most,
    /// so the space still reads as its color over a light desktop.
    var coverage: CGFloat { CGFloat(1 - (usesClearGlass ? 0.75 : 0.5) * seeThrough) }

    /// The window frame color for this space, solid.
    var background: NSColor {
        if let brightness { return SpaceColor.paint(hue: baseHue, depth: brightness, tint: tintAmount) }
        if let (day, night) = followsDepths {
            return Tokens.Color.dynamic(light: SpaceColor.paint(hue: baseHue, depth: day, tint: tintAmount),
                                        dark: SpaceColor.paint(hue: baseHue, depth: night, tint: tintAmount))
        }
        if isNeutral {
            // Following the Mac and see-through: clear white by day, smoked black at night.
            if isSeeThrough { return Tokens.Color.dynamic(light: .white, dark: .black) }
            return color.isNeutral ? color.background : SpaceColor.graphite.background
        }
        return hue.map { SpaceColor.background(hue: $0, intensity: intensity ?? SpaceColor.defaultIntensity) } ?? color.background
    }
    /// The strong version, for dots and swatches.
    var swatch: NSColor {
        if let brightness {
            return isNeutral ? NSColor(white: 0.86 - 0.56 * brightness, alpha: 1)
                : SpaceColor.paint(hue: baseHue, depth: 0.35 + 0.45 * brightness, tint: tintAmount)
        }
        if let (day, night) = followsDepths {
            return Tokens.Color.dynamic(light: SpaceColor.paint(hue: baseHue, depth: 0.35 + 0.45 * day, tint: tintAmount),
                                        dark: SpaceColor.paint(hue: baseHue, depth: 0.35 + 0.45 * night, tint: tintAmount))
        }
        if isNeutral { return color.isNeutral ? color.swatch : SpaceColor.graphite.swatch }
        return hue.map(SpaceColor.swatch(hue:)) ?? color.swatch
    }
    /// The hue the space is built on, curated or custom.
    var baseHue: Double { hue ?? color.hue }
    /// Where the gradient ends.
    var background2: NSColor? {
        hue2.map { h in
            if let depth = brightness2 ?? brightness { return SpaceColor.paint(hue: h, depth: depth, tint: tintAmount2) }
            if let (day, night) = followsDepths {
                return Tokens.Color.dynamic(light: SpaceColor.paint(hue: h, depth: day, tint: tintAmount2),
                                            dark: SpaceColor.paint(hue: h, depth: night, tint: tintAmount2))
            }
            return SpaceColor.background(hue: h, intensity: intensity2 ?? intensity ?? SpaceColor.defaultIntensity)
        }
    }
    var gradientAngle: Double { angle ?? 45 }

    /// The frame as the window lays it down: the color, thinned when see-through so the desktop shows under it.
    /// Over glass the color leans toward the space's strong version (its dot's) the more shows through, so a thin
    /// wash still reads as the space's color instead of gray.
    var frameColor: NSColor {
        guard isSeeThrough else { return background }
        if clearTint == true { return Self.covering(background, by: coverage, deep: Tokens.Frame.clearNightCover) }
        return Self.covering(Self.richer(background, toward: swatch, by: isNeutral ? 0 : 0.6 * seeThrough), by: coverage)
    }
    var frameColor2: NSColor? {
        guard isSeeThrough else { return background2 }
        if clearTint == true { return background2.map { Self.covering($0, by: coverage, deep: Tokens.Frame.clearNightCover) } }
        return background2.map { Self.covering($0, by: coverage) }
    }

    /// `color` moved part of the way to `strong`, light and dark alike.
    private static func richer(_ color: NSColor, toward strong: NSColor, by amount: Double) -> NSColor {
        guard amount > 0 else { return color }
        return NSColor(name: nil) { appearance in
            var a = color, b = strong
            appearance.performAsCurrentDrawingAppearance {
                a = color.usingColorSpace(.sRGB) ?? color
                b = strong.usingColorSpace(.sRGB) ?? strong
            }
            // At night the color is already deep and rich: only a touch, so the frame stays dark under light text.
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return a.blended(withFraction: CGFloat(dark ? amount * 0.3 : amount), of: b) ?? a
        }
    }

    /// `a` moved `share` of the way to `b`, alpha included, light and dark alike: a look partway through a swipe.
    static func mix(_ a: NSColor, _ b: NSColor, by share: CGFloat) -> NSColor {
        let t = min(max(share, 0), 1)
        if t == 0 { return a }
        if t == 1 { return b }
        return NSColor(name: nil) { appearance in
            var x: NSColor?, y: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                x = a.usingColorSpace(.sRGB)
                y = b.usingColorSpace(.sRGB)
            }
            guard let x, let y else { return t < 0.5 ? a : b }
            return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                           green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                           blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                           alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * t)
        }
    }

    /// `color` at `alpha`, still following light and dark when it does; in a dark window at least `deep`.
    private static func covering(_ color: NSColor, by alpha: CGFloat, deep: CGFloat = 0) -> NSColor {
        guard alpha < 1 else { return color }
        return NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return resolved.withAlphaComponent(dark ? max(alpha, deep) : alpha)
        }
    }

    /// How see-through a space saved as glass before 0.4 becomes: its old wash covered the desktop by half, so it
    /// lands where `coverage` is a half.
    static let glassTranslucency = 0.5 / 0.5

    /// The space as this version keeps it, looking just as it did: white, grays and black get no tint, and glass
    /// becomes a see-through gray at the shade it had.
    var upgraded: SpaceInfo {
        var space = self
        if hue == nil, color.isNeutral, tint == nil { space.tint = 0 }
        if glass == true {
            space.glass = nil
            space.translucency = translucency ?? Self.glassTranslucency
            // It was frosted, and stays so: the new clear default is for spaces made see-through from now on.
            space.clearGlass = false
            space.tint = 0
            space.hue2 = nil
            space.brightness2 = nil
            space.tint2 = nil
            space.brightness = brightness.map { SpaceColor.depth(ofWhite: 1 - $0) }
        }
        if clearTint == nil, isSeeThrough { space.upgradeEarlierPalette() }
        return space
    }

    /// A palette look saved by the 0.9.4 betas before the palette's clear glass takes the clear glass, as picked or as
    /// a new space had it. Grain of its own stays.
    private mutating func upgradeEarlierPalette() {
        let ownGrain = grain
        for color in SpaceColor.palette {
            guard let earlier = color.earlierLook else { continue }
            func matches(_ look: SpaceLook) -> Bool {
                var look = look
                look.grain = ownGrain ?? 0
                return look.matches(self)
            }
            let picked = matches(SpaceLook.palette(color, earlier, following: false, clear: false))
            guard picked || matches(SpaceLook.palette(color, earlier, following: true, clear: false)) else { continue }
            guard let look = picked ? color.look : color.defaultLook else { return }
            look.apply(to: &self)
            if let ownGrain, ownGrain > 0 {
                grain = ownGrain
                texture = nil
            }
            return
        }
    }

    /// The space with the colors a new one gets: `color` alone, light by day and dark at night with the Mac, with no
    /// gradient, see-through or grain; a palette color, its look. Its name, icon, pages and the rest stay.
    func withDefaultColors(_ color: SpaceColor) -> SpaceInfo {
        var space = self
        space.color = color
        space.hue = nil
        space.intensity = nil
        space.hue2 = nil
        space.intensity2 = nil
        space.angle = nil
        space.glass = nil
        space.brightness = nil
        space.brightness2 = nil
        space.dayDepth = nil
        space.nightDepth = nil
        space.tint = nil
        space.tint2 = nil
        space.translucency = nil
        space.clearGlass = nil
        space.clearTint = nil
        space.grain = nil
        space.texture = nil
        space.appearance = nil
        // The palette's colors come on clear glass, following the Mac; the older ones are one solid color.
        color.defaultLook?.apply(to: &space)
        return space.upgraded
    }

    /// Whether the space looks just as `withDefaultColors(color)` does. What can't show is left out: a gradient's
    /// direction once it's one color, and clear or frosted glass on a solid space.
    func hasDefaultColors(_ color: SpaceColor) -> Bool {
        func look(_ space: SpaceInfo) -> [String] {
            let s = space.upgraded
            let two = s.hue2 != nil
            let values: [Any?] = [s.color.rawValue, s.hue, s.intensity, s.brightness, s.tint, s.translucency, s.grain, s.appearance,
                                  s.hue2, two ? s.intensity2 : nil, two ? s.brightness2 : nil, two ? s.tint2 : nil, two ? s.angle : nil,
                                  s.isSeeThrough ? s.clearGlass : nil, s.dayDepth, s.nightDepth, s.clearTint, s.grain == nil ? nil : s.texture]
            return values.map { $0.map { "\($0)" } ?? "-" }
        }
        return look(self) == look(withDefaultColors(color))
    }

    /// Light or dark for the window: whichever text reads better on this space's own colors, judged at the
    /// harder end of a gradient. See-through spaces are judged the same way: the frosting under them follows the
    /// mode chosen, so it lands on the same side. Spaces that follow the Mac keep what they were given.
    var readableAppearance: String? {
        guard brightness != nil else {
            // White and black stay themselves day and night, so the window's mode stays with them, never black text on black.
            if appearance == nil, hue == nil, !isSeeThrough { if color == .ink { return "dark" }; if color == .snow { return "light" } }
            // A palette color deep by day too (red), or light at night too (citron), keeps its mode; the rest follow the Mac.
            if appearance == nil, followsDepths != nil {
                func mode(_ name: NSAppearance.Name) -> String? {
                    var shown: String?
                    NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                        shown = Self.readable(on: [background] + (background2.map { [$0] } ?? []))
                    }
                    return shown
                }
                let day = mode(.aqua), night = mode(.darkAqua)
                return day == night ? day : nil
            }
            return appearance
        }
        return Self.readable(on: [background] + (background2.map { [$0] } ?? []))
    }

    /// "light" or "dark": whichever text reads better on all of `colors`, as they resolve now.
    private static func readable(on colors: [NSColor]) -> String {
        func luminance(_ color: NSColor) -> Double {
            guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
            func linear(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        // WCAG contrast of black text and of white text, each at its worst across the colors.
        let lums = colors.map(luminance)
        let black = lums.map { ($0 + 0.05) / 0.05 }.min() ?? 1
        let white = lums.map { 1.05 / ($0 + 0.05) }.min() ?? 1
        return black >= white ? "light" : "dark"
    }
}

/// Written so an older Zigzag can still read it: `color` and `defaultColor` hold a color it knows, the nearest one,
/// and a palette color goes under keys of its own, which this one reads first.
extension SpaceInfo {
    private enum CodingKeys: String, CodingKey {
        case id, name, color, bookmarks, folders, pinnedSplits, hue, intensity, appearance, grain, hue2, intensity2, angle,
             glass, brightness, brightness2, dayDepth, nightDepth, tint, tint2, translucency, clearGlass, clearTint, texture, icon, importedFrom, defaultColor,
             routedSites, backgroundImage, paletteColor, paletteDefaultColor
    }

    /// A stored color's name; one this version doesn't know reads as nil.
    private static func color(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> SpaceColor? {
        ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap(SpaceColor.named)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        // A beta that wrote a palette color into `color` reads as it was, and is written the compatible way next time;
        // the betas' palette names read as the colors that took their place.
        color = Self.color(c, .paletteColor) ?? Self.color(c, .color) ?? .graphite
        defaultColor = Self.color(c, .paletteDefaultColor) ?? Self.color(c, .defaultColor)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        folders = try c.decodeIfPresent([BookmarkFolder].self, forKey: .folders)
        pinnedSplits = try c.decodeIfPresent([PinnedSplit].self, forKey: .pinnedSplits)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity)
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance)
        grain = try c.decodeIfPresent(Double.self, forKey: .grain)
        hue2 = try c.decodeIfPresent(Double.self, forKey: .hue2)
        intensity2 = try c.decodeIfPresent(Double.self, forKey: .intensity2)
        angle = try c.decodeIfPresent(Double.self, forKey: .angle)
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        brightness2 = try c.decodeIfPresent(Double.self, forKey: .brightness2)
        dayDepth = try c.decodeIfPresent(Double.self, forKey: .dayDepth)
        nightDepth = try c.decodeIfPresent(Double.self, forKey: .nightDepth)
        tint = try c.decodeIfPresent(Double.self, forKey: .tint)
        tint2 = try c.decodeIfPresent(Double.self, forKey: .tint2)
        translucency = try c.decodeIfPresent(Double.self, forKey: .translucency)
        clearGlass = try c.decodeIfPresent(Bool.self, forKey: .clearGlass)
        clearTint = try c.decodeIfPresent(Bool.self, forKey: .clearTint)
        texture = try c.decodeIfPresent(String.self, forKey: .texture)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        importedFrom = try c.decodeIfPresent(String.self, forKey: .importedFrom)
        routedSites = try c.decodeIfPresent([String].self, forKey: .routedSites)
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(color.nearestLegacy, forKey: .color)
        if color != color.nearestLegacy { try c.encode(color, forKey: .paletteColor) }
        try c.encodeIfPresent(defaultColor?.nearestLegacy, forKey: .defaultColor)
        if let defaultColor, defaultColor != defaultColor.nearestLegacy { try c.encode(defaultColor, forKey: .paletteDefaultColor) }
        try c.encode(bookmarks, forKey: .bookmarks)
        try c.encodeIfPresent(folders, forKey: .folders)
        try c.encodeIfPresent(pinnedSplits, forKey: .pinnedSplits)
        try c.encodeIfPresent(hue, forKey: .hue)
        try c.encodeIfPresent(intensity, forKey: .intensity)
        try c.encodeIfPresent(appearance, forKey: .appearance)
        try c.encodeIfPresent(grain, forKey: .grain)
        try c.encodeIfPresent(hue2, forKey: .hue2)
        try c.encodeIfPresent(intensity2, forKey: .intensity2)
        try c.encodeIfPresent(angle, forKey: .angle)
        try c.encodeIfPresent(glass, forKey: .glass)
        try c.encodeIfPresent(brightness, forKey: .brightness)
        try c.encodeIfPresent(brightness2, forKey: .brightness2)
        try c.encodeIfPresent(dayDepth, forKey: .dayDepth)
        try c.encodeIfPresent(nightDepth, forKey: .nightDepth)
        try c.encodeIfPresent(tint, forKey: .tint)
        try c.encodeIfPresent(tint2, forKey: .tint2)
        try c.encodeIfPresent(translucency, forKey: .translucency)
        try c.encodeIfPresent(clearGlass, forKey: .clearGlass)
        try c.encodeIfPresent(clearTint, forKey: .clearTint)
        try c.encodeIfPresent(texture, forKey: .texture)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(importedFrom, forKey: .importedFrom)
        try c.encodeIfPresent(routedSites, forKey: .routedSites)
        try c.encodeIfPresent(backgroundImage, forKey: .backgroundImage)
    }
}

enum SearchEngine: String, Codable, CaseIterable {
    case google, duckDuckGo, brave, bing, kagi, ecosia, startpage, perplexity, yahoo, baidu, yandex, custom
    /// The one an extension gives ("ChatGPT search"), while it's on: see ExtensionSearchProvider.
    case fromExtension

    /// Zigzag's own engines, the ones Settings always lists.
    static var builtIn: [SearchEngine] { allCases.filter { $0 != .fromExtension } }

    /// An engine this version doesn't know (saved by a newer one) reads as Google, rather than making the whole
    /// library unreadable and losing every space with it.
    init(from decoder: Decoder) throws {
        self = SearchEngine(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .google
    }

    /// A search address of your own, with %s where the words go ("https://example.com/search?q=%s").
    static var customTemplate: String {
        get { UserDefaults.standard.string(forKey: "CustomSearchTemplate") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "CustomSearchTemplate") }
    }

    /// What you typed, encoded to go into a search address where the words go.
    static func encodedWords(_ query: String) -> String {
        query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? query
    }

    /// Whether a custom address can search: http or https, with a host and a %s for the words.
    static func isValidTemplate(_ template: String) -> Bool {
        guard template.contains("%s"), let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return false }
        return true
    }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave Search"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        case .startpage: "Startpage"
        case .perplexity: "Perplexity"
        case .yahoo: "Yahoo"
        case .baidu: "Baidu"
        case .yandex: "Yandex"
        case .custom:
            URL(string: Self.customTemplate.replacingOccurrences(of: "%s", with: "q")).flatMap { Self.isValidTemplate(Self.customTemplate) ? $0.host() : nil }
                ?? String(localized: "Custom", comment: "A search engine choice in Settings: one you give an address for.")
        case .fromExtension: ExtensionSearchProvider.chosen?.name ?? ExtensionSearchProvider.previousEngine.name
        }
    }

    func searchURL(_ query: String) -> URL {
        var components: URLComponents
        var key = "q"
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")!
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
        case .brave: components = URLComponents(string: "https://search.brave.com/search")!
        case .bing: components = URLComponents(string: "https://www.bing.com/search")!
        case .kagi: components = URLComponents(string: "https://kagi.com/search")!
        case .ecosia: components = URLComponents(string: "https://www.ecosia.org/search")!
        case .startpage: components = URLComponents(string: "https://www.startpage.com/sp/search")!; key = "query"
        case .perplexity: components = URLComponents(string: "https://www.perplexity.ai/search")!
        case .yahoo: components = URLComponents(string: "https://search.yahoo.com/search")!; key = "p"
        case .baidu: components = URLComponents(string: "https://www.baidu.com/s")!; key = "wd"
        case .yandex: components = URLComponents(string: "https://yandex.com/search/")!; key = "text"
        case .custom:
            // The words go where %s is, encoded; an address that can't search falls back to Google.
            let template = Self.customTemplate
            if Self.isValidTemplate(template), let url = URL(string: template.replacingOccurrences(of: "%s", with: Self.encodedWords(query))) { return url }
            return SearchEngine.google.searchURL(query)
        case .fromExtension:
            // The extension went off since: the engine you had before it.
            return ExtensionSearchProvider.chosen?.searchURL(query) ?? ExtensionSearchProvider.previousEngine.searchURL(query)
        }
        components.queryItems = [URLQueryItem(name: key, value: query)]
        return components.url!
    }

    /// The engine's home page, for its icon.
    var homeURL: URL {
        switch self {
        case .google: URL(string: "https://www.google.com")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com")!
        case .brave: URL(string: "https://search.brave.com")!
        case .bing: URL(string: "https://www.bing.com")!
        case .kagi: URL(string: "https://kagi.com")!
        case .ecosia: URL(string: "https://www.ecosia.org")!
        case .startpage: URL(string: "https://www.startpage.com")!
        case .perplexity: URL(string: "https://www.perplexity.ai")!
        case .yahoo: URL(string: "https://search.yahoo.com")!
        case .baidu: URL(string: "https://www.baidu.com")!
        case .yandex: URL(string: "https://yandex.com")!
        case .custom:
            URL(string: Self.customTemplate.replacingOccurrences(of: "%s", with: "q")).flatMap { url in
                url.host().flatMap { URL(string: "\(url.scheme ?? "https")://\($0)") }
            } ?? URL(string: "https://www.google.com")!
        case .fromExtension: ExtensionSearchProvider.chosen?.homeURL ?? ExtensionSearchProvider.previousEngine.homeURL
        }
    }

    func suggestionsURL(_ query: String) -> URL? {
        var components: URLComponents
        switch self {
        case .google:
            components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            components.queryItems = [.init(name: "client", value: "firefox"), .init(name: "q", value: query)]
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/ac/")!
            components.queryItems = [.init(name: "type", value: "list"), .init(name: "q", value: query)]
        case .brave:
            components = URLComponents(string: "https://search.brave.com/api/suggest")!
            components.queryItems = [.init(name: "q", value: query)]
        case .bing:
            components = URLComponents(string: "https://api.bing.com/osjson.aspx")!
            components.queryItems = [.init(name: "query", value: query)]
        case .kagi:
            components = URLComponents(string: "https://kagi.com/api/autosuggest")!
            components.queryItems = [.init(name: "q", value: query)]
        case .ecosia:
            components = URLComponents(string: "https://ac.ecosia.org/autocomplete")!
            components.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "list")]
        case .startpage, .perplexity, .yahoo, .baidu, .yandex, .custom:
            // No suggestions service these engines offer in a form Zigzag reads: what you type stays on your Mac.
            return nil
        case .fromExtension:
            // Only when the extension names a suggestions address of its own.
            return ExtensionSearchProvider.chosen?.suggestionsURL(query)
        }
        return components.url
    }
}

/// Everything the user keeps that is not a tab: spaces, bookmarks, and the two settings.
final class Library {
    static let shared = Library()

    private struct Stored: Codable {
        var spaces: [SpaceInfo]
        var favorites: [Bookmark]?
        var siteRoutes: SiteRoutes.StoredRules?
        var favoriteSplits: [PinnedSplit]?
        var searchEngine: SearchEngine
        var importedFromArc: Bool?
    }

    private var storedRoutes = SiteRoutes.StoredRules()
    private(set) var siteRoutes: [SiteRoutes.Route] {
        get { storedRoutes.rules }
        set { storedRoutes.rules = newValue }
    }
    private(set) var spaces: [SpaceInfo]
    /// Favorites: tiles at the top of the sidebar, the same in every space of a profile. Every profile's are here,
    /// each profile's in its own order; whose a favorite is, is in `directory`. `favorites(in:)` is one profile's.
    private(set) var favorites: [Bookmark] = []
    /// Favorites kept together as a split view: one tile, two pages side by side. In `favorites` the right page
    /// follows the left.
    private(set) var favoriteSplits: [PinnedSplit] = []
    var searchEngine: SearchEngine { didSet { save() } }
    var importedFromArc: Bool { didSet { save() } }

    /// The profiles there are, and which space is on which (Profiles.json).
    private(set) var directory: ProfileDirectory
    /// What Profiles.json held when it was last read or written, so it's only written when it has changed: someone
    /// who never makes a second profile never gets the file.
    private var savedDirectory: ProfileDirectory
    /// Profiles.json was there but couldn't be read, so it was set aside (JSONStore) and every space is on the first
    /// profile for now. Said once, at launch.
    let profilesWereSetAside: Bool

    /// Fires whenever spaces or bookmarks change.
    let changed = Signal<Void>()
    /// Whether the library was read from its file, not started afresh (a first run, or a file that couldn't be read).
    private let wasRead: Bool

    private init() {
        let hadProfiles = FileManager.default.fileExists(atPath: Paths.profiles.path)
        let readProfiles = hadProfiles ? JSONStore.load(ProfileDirectory.self, from: Paths.profiles) : nil
        directory = readProfiles ?? ProfileDirectory()
        profilesWereSetAside = hadProfiles && readProfiles == nil
        savedDirectory = directory
        if let stored = JSONStore.load(Stored.self, from: Paths.library), !stored.spaces.isEmpty {
            spaces = Self.keepingDefaultColors(stored.spaces.map(\.upgraded))
            storedRoutes = stored.siteRoutes ?? SiteRoutes.StoredRules(SiteRoutes.migrated(from: spaces))
            // The rules are what counts now. The old lists are only written for an older Zigzag.
            for i in spaces.indices { spaces[i].routedSites = nil }
            favorites = stored.favorites ?? []
            favoriteSplits = stored.favoriteSplits ?? []
            searchEngine = stored.searchEngine
            importedFromArc = stored.importedFromArc ?? false
            wasRead = true
            // What an older Zigzag may have left that this one doesn't allow.
            tidyFavorites()
            // Save the new rule IDs and order on the first launch after upgrade.
            if stored.siteRoutes == nil { saveNow() }
        } else {
            wasRead = false
            let first = SpaceColor.newSpaceOrder[0]
            spaces = [SpaceInfo(name: String(localized: "Personal", comment: "The name of the first space in a new Zigzag. People can rename it."), color: first, defaultColor: first).withDefaultColors(first)]
            searchEngine = .google
            importedFromArc = false
            saveNow()
        }
    }

    private let saveDebouncer = Debouncer(delay: 0.5, maxWait: 5)

    func save() {
        saveDebouncer.call { [self] in saveNow() }
    }

    func saveNow() {
        saveDebouncer.cancel()
        JSONStore.save(Stored(spaces: SiteRoutes.withLegacySites(spaces, from: siteRoutes), favorites: favorites, siteRoutes: storedRoutes, favoriteSplits: favoriteSplits.isEmpty ? nil : favoriteSplits,
                              searchEngine: searchEngine, importedFromArc: importedFromArc), to: Paths.library)
        // Only what reached the disk counts as saved: a write that failed is tried again with the next save.
        if directory != savedDirectory, JSONStore.save(directory, to: Paths.profiles) { savedDirectory = directory }
    }

    private func commit() {
        if holding > 0 { held = true; return }
        save()
        changed.send()
    }

    private var holding = 0
    private var held = false

    /// Many changes as one: saved and shown once, at the end, not once for each (a hundred picked rows unpinned).
    func together(_ body: () -> Void) {
        holding += 1
        body()
        holding -= 1
        if holding == 0, held { held = false; commit() }
    }

    /// Fires as a browser import starts (true) and finishes (false) adding pages and spaces, with the profile it goes into.
    let bookmarkImport = Signal<(started: Bool, profile: UUID)>()

    /// A browser import's changes to the library, between the two `bookmarkImport` signals.
    func importing<T>(into profile: UUID, _ body: () -> T) -> T {
        bookmarkImport.send((true, profile))
        defer { bookmarkImport.send((false, profile)) }
        return body()
    }

    // MARK: Spaces

    func space(_ id: UUID) -> SpaceInfo? { spaces.first { $0.id == id } }

    func index(of id: UUID) -> Int? { spaces.firstIndex { $0.id == id } }

    /// Settings › Spaces: new spaces get their own profile (#291). Off by default; existing and imported spaces are
    /// unchanged.
    static var newSpacesGetOwnProfile: Bool {
        get { UserDefaults.standard.bool(forKey: "NewSpacesGetOwnProfile") }
        set { UserDefaults.standard.set(newValue, forKey: "NewSpacesGetOwnProfile") }
    }

    /// A new space on `profile`, or with `ownProfile` on a new profile named after it.
    @discardableResult
    func addSpace(name: String? = nil, color: SpaceColor? = nil, profile: UUID = Profile.defaultID, ownProfile: Bool = false) -> SpaceInfo {
        let pick = color ?? SpaceColor.next(unused: spaces.map(\.color))
        var space = SpaceInfo(name: name ?? String(localized: "Space \(spaces.count + 1)", comment: "The name of a new space: its number. People can rename it."),
                              color: pick).withDefaultColors(pick)
        space.defaultColor = pick
        spaces.append(space)
        directory.place(newSpace: space, on: profile, ownProfile: ownProfile, usedColors: profiles.map { self.color(of: $0) })
        commit()
        return space
    }

    /// Notes which browser profile an import made this space for, so the next import of it lands here again.
    func setImportedFrom(_ key: String, forSpace id: UUID) {
        guard let i = index(of: id), spaces[i].importedFrom != key else { return }
        spaces[i].importedFrom = key
        commit()
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let i = index(of: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        spaces[i].name = trimmed
        commit()
    }

    func setIcon(_ icon: String?, forSpace id: UUID) {
        guard let i = index(of: id), spaces[i].icon != icon else { return }
        spaces[i].icon = icon
        commit()
    }

    /// Sets the space's background, deleting the previous file.
    func setBackgroundImage(_ name: String?, forSpace id: UUID) {
        guard let i = index(of: id), spaces[i].backgroundImage != name else { return }
        let old = spaces[i].backgroundImage
        spaces[i].backgroundImage = name
        commit()
        SpaceBackground.remove(old)
    }

    /// The color each space was given when it was made, in order. A space from before that was kept still has it as
    /// its `color`, unless a white, gray or black look took its place: then it's the one a space made in its place
    /// would get, as `addSpace` picks.
    static func defaultColors(of spaces: [SpaceInfo]) -> [SpaceColor] {
        var made: [SpaceColor] = []
        for space in spaces {
            if let kept = space.defaultColor { made.append(kept) }
            // Spaces not kept were made before the new palette, so they got the colors of then.
            else if space.color == .graphite, space.brightness != nil { made.append(SpaceColor.legacyNext(unused: made)) }
            else { made.append(space.color) }
        }
        return made
    }

    /// Every space with the color it was made with kept, worked out once as the library opens, so moving or
    /// deleting spaces later doesn't change it.
    static func keepingDefaultColors(_ spaces: [SpaceInfo]) -> [SpaceInfo] {
        zip(spaces, defaultColors(of: spaces)).map { space, color in
            var space = space
            space.defaultColor = space.defaultColor ?? color
            return space
        }
    }

    /// The color Use Default Colors gives the space.
    func defaultColor(ofSpace id: UUID) -> SpaceColor? {
        guard let i = index(of: id) else { return nil }
        return spaces[i].defaultColor ?? Self.defaultColors(of: spaces)[i]
    }

    /// Whether the space still has the colors it was made with, so there's nothing for Use Default Colors to do.
    func hasDefaultColors(_ id: UUID) -> Bool {
        guard let space = space(id), let color = defaultColor(ofSpace: id) else { return true }
        return space.hasDefaultColors(color)
    }

    /// The colors the space was made with, back again.
    func useDefaultColors(forSpace id: UUID) {
        guard let space = space(id), let color = defaultColor(ofSpace: id), !space.hasDefaultColors(color) else { return }
        setLook(space.withDefaultColors(color))
    }

    /// Before a space's colors first change, the color it was made with is kept, so it stays the same however the
    /// spaces are moved or changed after.
    private func keepDefaultColor(_ i: Int) {
        if spaces[i].defaultColor == nil { spaces[i].defaultColor = Self.defaultColors(of: spaces)[i] }
    }

    func setColor(_ color: SpaceColor, for id: UUID) {
        guard let i = index(of: id) else { return }
        keepDefaultColor(i)
        spaces[i].color = color
        spaces[i].hue = nil
        spaces[i].intensity = nil
        spaces[i].dayDepth = nil
        spaces[i].nightDepth = nil
        spaces[i].clearTint = nil
        spaces[i].tint = nil
        commit()
    }

    /// Everything about how a space looks, from the space editor, in one save.
    func setLook(_ look: SpaceInfo) {
        guard let i = index(of: look.id) else { return }
        keepDefaultColor(i)
        spaces[i].color = look.color
        spaces[i].hue = look.hue
        spaces[i].intensity = look.intensity
        spaces[i].hue2 = look.hue2
        spaces[i].intensity2 = look.intensity2
        spaces[i].brightness = look.brightness
        spaces[i].brightness2 = look.brightness2
        spaces[i].dayDepth = look.dayDepth
        spaces[i].nightDepth = look.nightDepth
        spaces[i].angle = look.angle
        spaces[i].tint = look.tint
        spaces[i].tint2 = look.tint2
        spaces[i].translucency = look.translucency
        spaces[i].clearGlass = look.clearGlass
        spaces[i].clearTint = look.clearTint
        spaces[i].glass = nil
        spaces[i].grain = look.grain
        spaces[i].texture = look.texture
        spaces[i].appearance = look.appearance
        commit()
    }

    /// Nil: automatic. Otherwise the window's mode follows it: light for the lighter half, dark for the darker.
    func setBrightness(_ brightness: Double?, for id: UUID) {
        guard let i = index(of: id) else { return }
        keepDefaultColor(i)
        spaces[i].brightness = brightness
        spaces[i].appearance = brightness.map { $0 < 0.5 ? "light" : "dark" }
        commit()
    }

    func setGrain(_ grain: Double, for id: UUID) {
        guard let i = index(of: id) else { return }
        keepDefaultColor(i)
        spaces[i].grain = grain > 0.01 ? min(grain, 1) : nil
        commit()
    }

    func setHue(_ hue: Double, intensity: Double? = nil, for id: UUID) {
        guard let i = index(of: id) else { return }
        keepDefaultColor(i)
        spaces[i].hue = hue
        spaces[i].tint = nil
        spaces[i].dayDepth = nil
        spaces[i].nightDepth = nil
        spaces[i].clearTint = nil
        if let intensity { spaces[i].intensity = intensity }
        commit()
    }

    func removeSpace(_ id: UUID) {
        // One of your spaces is always left.
        guard yourSpaces.contains(where: { $0.id != id }), let i = index(of: id) else { return }
        spaces.remove(at: i)
        siteRoutes.removeAll { $0.spaceID == id }
        commit()
    }

    /// Puts back a removed space, bookmarks and all, at its old place (undo).
    func insertSpace(_ space: SpaceInfo, at index: Int, routes: [(offset: Int, element: SiteRoutes.Route)] = []) {
        guard self.index(of: space.id) == nil else { return }
        spaces.insert(space, at: max(0, min(index, spaces.count)))
        for (offset, rule) in routes { siteRoutes.insert(rule, at: min(offset, siteRoutes.count)) }
        commit()
    }

    // MARK: Sites that open in a space (#286)

    func siteRoute(for url: URL?) -> SiteRoutes.Route? { SiteRoutes.route(for: url, in: siteRoutes) }

    func saveRoute(_ rule: SiteRoutes.Route) {
        guard space(rule.spaceID) != nil else { return }
        if let index = siteRoutes.firstIndex(where: { $0.id == rule.id }) {
            siteRoutes[index] = rule
        } else {
            siteRoutes.append(rule)
        }
        commit()
    }

    func removeRoute(_ id: UUID) {
        siteRoutes.removeAll { $0.id == id }
        commit()
    }

    func moveRoute(_ id: UUID, before next: UUID?) {
        SiteRoutes.move(id, before: next, in: &siteRoutes)
        commit()
    }

    func moveSpace(_ id: UUID, to newIndex: Int) {
        guard let i = index(of: id) else { return }
        let space = spaces.remove(at: i)
        spaces.insert(space, at: max(0, min(newIndex, spaces.count)))
        commit()
    }

    // MARK: Bookmarks

    func bookmarks(in spaceID: UUID) -> [Bookmark] { space(spaceID)?.bookmarks ?? [] }

    /// Space bookmarks with their space (favorites are separate: `favorites`).
    var allBookmarks: [(Bookmark, SpaceInfo)] {
        spaces.flatMap { space in space.bookmarks.map { ($0, space) } }
    }

    func bookmark(_ id: UUID) -> Bookmark? {
        if let favorite = favorites.first(where: { $0.id == id }) { return favorite }
        for space in spaces { if let b = space.bookmarks.first(where: { $0.id == id }) { return b } }
        return nil
    }

    // MARK: Favorites

    func isFavorite(_ id: UUID) -> Bool { favorites.contains { $0.id == id } }

    /// Every bookmark and favorite id, for checking what still exists.
    var allBookmarkIDs: Set<UUID> {
        Set(favorites.map(\.id) + spaces.flatMap { $0.bookmarks.map(\.id) })
    }

    /// A profile's favorites, in its order.
    func favorites(in profile: UUID) -> [Bookmark] {
        // With one profile every favorite is its own: nothing to look up.
        hasManyProfiles ? favorites.filter { directory.profileID(ofFavorite: $0.id) == profile } : favorites
    }

    func profileID(ofFavorite id: UUID) -> UUID { directory.profileID(ofFavorite: id) }

    /// A profile's favorites as the grid shows them: one tile each, a split's or tile group's pages in one (its first
    /// page leads, the others its `partners`, in order).
    func favoriteTiles(in profile: UUID) -> [(Bookmark, partners: [Bookmark])] {
        let favorites = favorites(in: profile)
        let riders = Set(favoriteSplits.flatMap(\.riders))
        let byID = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return favorites.filter { !riders.contains($0.id) }.map { favorite in
            (favorite, favoriteSplits.first { $0.left == favorite.id }.map { $0.riders.compactMap { byID[$0] } } ?? [])
        }
    }

    /// `slot` counts the profile's tiles, as the grid shows them; nil: at the end.
    @discardableResult
    func addFavorite(url: URL, title: String, icon: String? = nil, at slot: Int? = nil, id: UUID = UUID(), in profile: UUID) -> Bookmark {
        let favorite = Bookmark(id: id, url: url, title: title, icon: icon)
        arrangeFavorites(Self.placing([id], atSlot: slot, in: favorites(in: profile).map(\.id), splits: favoriteSplits), adding: [favorite], in: profile)
        commit()
        return favorite
    }

    /// A split's two pages, or a tile group's three or four, as one favorite at a tile's place, laid out as `layout`
    /// (whose pages are `marks`, in order).
    func addFavoriteSplit(_ marks: [Bookmark], as layout: PinnedSplit, at slot: Int? = nil, in profile: UUID) {
        let ids = marks.map(\.id)
        guard ids == layout.ids else { return }
        favoriteSplits.removeAll { split in ids.contains(where: split.contains) }
        arrangeFavorites(Self.placing(ids, atSlot: slot, in: favorites(in: profile).map(\.id), splits: favoriteSplits), adding: marks, in: profile)
        favoriteSplits.append(layout)
        tidyFavorites()
        commit()
    }

    /// A page (a favorite, or one becoming one) joins the favorite `targetID`: the two become one split favorite where
    /// that favorite's tile is, the page on the right or the left. The page is then that favorite's profile's.
    func joinFavorite(_ page: Bookmark, onto targetID: UUID, onRight: Bool) {
        guard let target = favorites.first(where: { $0.id == targetID }), page.id != targetID else { return }
        let (left, right) = onRight ? (target, page) : (page, target)
        let profile = profileID(ofFavorite: targetID)
        favoriteSplits.removeAll { $0.contains(left.id) || $0.contains(right.id) }
        arrangeFavorites(Self.placing([left.id, right.id], at: targetID, in: favorites(in: profile).map(\.id)), adding: [page], in: profile)
        favoriteSplits.append(PinnedSplit(left: left.id, right: right.id))
        tidyFavorites()
        commit()
    }

    /// Moves a favorite (and its split's other page with it) to a tile's place.
    func moveFavorite(_ id: UUID, to slot: Int) {
        guard isFavorite(id) else { return }
        let ids = favoriteSplits.first { $0.contains(id) }.map(\.ids) ?? [id]
        let profile = profileID(ofFavorite: id)
        arrangeFavorites(Self.placing(ids, atSlot: slot, in: favorites(in: profile).map(\.id), splits: favoriteSplits), in: profile)
        commit()
    }

    /// Puts a profile's favorites (and any new ones, or ones that become its) in this order. The other profiles'
    /// keep theirs.
    private func arrangeFavorites(_ order: [UUID], adding new: [Bookmark] = [], in profile: UUID) {
        favorites = Self.arranging(favorites, as: order, adding: new)
        for id in order { directory.assign(favorite: id, to: profile) }
    }

    /// Every profile's favorites with one profile's put in `order` (its own, and any in `new`); the rest stay as
    /// they were, ahead of them.
    nonisolated static func arranging(_ favorites: [Bookmark], as order: [UUID], adding new: [Bookmark] = []) -> [Bookmark] {
        let byID = Dictionary((favorites + new).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ordered = Set(order)
        return favorites.filter { !ordered.contains($0.id) } + order.compactMap { byID[$0] }
    }

    /// The favorites' ids with `moving` (one tile's pages) put before the tile at `slot` among the rest, or after the
    /// last (nil, or past the end). A split's pages but its first don't count as tiles of their own.
    nonisolated static func placing(_ moving: [UUID], atSlot slot: Int?, in ids: [UUID], splits: [PinnedSplit]) -> [UUID] {
        let rights = Set(splits.flatMap(\.riders))
        var rest = ids.filter { !moving.contains($0) }
        let tiles = rest.filter { !rights.contains($0) }
        let at = slot.flatMap { $0 >= 0 && $0 < tiles.count ? rest.firstIndex(of: tiles[$0]) : nil } ?? rest.count
        rest.insert(contentsOf: moving, at: at)
        return rest
    }

    /// The favorites' ids with `moving` put where `anchor` is now, counted without the ones that move.
    nonisolated static func placing(_ moving: [UUID], at anchor: UUID, in ids: [UUID]) -> [UUID] {
        let at = ids.prefix { $0 != anchor }.filter { !moving.contains($0) }.count
        var rest = ids.filter { !moving.contains($0) }
        rest.insert(contentsOf: moving, at: min(at, rest.count))
        return rest
    }

    /// Turns a space bookmark into a favorite at a tile's place (nil: the end), keeping its id (and so its live page).
    /// A page of a pinned split or group brings the rest: they stay one split, now a favorite.
    func makeFavorite(_ bookmarkID: UUID, at slot: Int? = nil, in profile: UUID) {
        guard let bookmark = bookmark(bookmarkID), !isFavorite(bookmarkID) else { return }
        if let pinned = pinnedSplit(containing: bookmarkID), case let marks = pinned.ids.compactMap(self.bookmark), marks.count == pinned.ids.count {
            for s in spaces.indices {
                spaces[s].bookmarks.removeAll { pinned.contains($0.id) }
                spaces[s].pinnedSplits?.removeAll { $0.contains(bookmarkID) }
                if spaces[s].pinnedSplits?.isEmpty == true { spaces[s].pinnedSplits = nil }
                tidyFolders(s)
            }
            arrangeFavorites(Self.placing(pinned.ids, atSlot: slot, in: favorites(in: profile).map(\.id), splits: favoriteSplits), adding: marks, in: profile)
            favoriteSplits.append(pinned)
            tidyFavorites()
            commit()
            return
        }
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == bookmarkID }; tidyFolders(s) }
        arrangeFavorites(Self.placing([bookmarkID], atSlot: slot, in: favorites(in: profile).map(\.id), splits: favoriteSplits), adding: [bookmark], in: profile)
        commit()
    }

    /// A favorite moved down among a space's pinned tabs, at a place in its list; a split favorite becomes a pinned
    /// split there.
    func pinFavorite(_ id: UUID, in spaceID: UUID, at index: Int) {
        guard let s = self.index(of: spaceID) else { return }
        let pair = favoriteSplits.first { $0.contains(id) }
        let ids = pair.map(\.ids) ?? [id]
        let moving = favorites.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        favorites.removeAll { ids.contains($0.id) }
        favoriteSplits.removeAll { $0.contains(id) }
        for id in ids { directory.assign(favorite: id, to: Profile.defaultID) }
        spaces[s].bookmarks.insert(contentsOf: moving, at: min(max(index, 0), spaces[s].bookmarks.count))
        if let pair { spaces[s].pinnedSplits = (spaces[s].pinnedSplits ?? []) + [pair] }
        tidyFolders(s)
        commit()
    }

    /// Takes a pinned page out of its space, to become a favorite; the caller commits.
    func detachBookmark(_ id: UUID) -> Bookmark? {
        guard let bookmark = spaces.lazy.compactMap({ $0.bookmarks.first { $0.id == id } }).first else { return nil }
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == id }; tidyFolders(s) }
        return bookmark
    }

    /// Each favorite split keeps different favorites, in no other split, each of its pages just after the one before.
    private func tidyFavorites() {
        (favorites, favoriteSplits) = Self.tidied(favorites, splits: favoriteSplits, directory: directory)
    }

    /// The favorites and their splits as they may be kept: each split different favorites of one profile, in no
    /// other split, each page just after the one before it. An older Zigzag, which shows every profile's favorites
    /// together, can pair two that aren't one profile's; half of such a pair would show in neither, so it's undone.
    nonisolated static func tidied(_ favorites: [Bookmark], splits: [PinnedSplit], directory: ProfileDirectory) -> ([Bookmark], [PinnedSplit]) {
        var favorites = favorites
        let ids = Set(favorites.map(\.id))
        var paired: Set<UUID> = []
        let splits = splits.filter { split in
            let pages = split.ids
            guard Set(pages).count == pages.count, pages.allSatisfy(ids.contains),
                  Set(pages.map { directory.profileID(ofFavorite: $0) }).count == 1,
                  paired.isDisjoint(with: pages) else { return false }
            paired.formUnion(pages)
            return true
        }
        for split in splits {
            for (previous, id) in zip(split.ids, split.riders) {
                guard let from = favorites.firstIndex(where: { $0.id == id }) else { continue }
                let page = favorites.remove(at: from)
                favorites.insert(page, at: (favorites.firstIndex { $0.id == previous } ?? favorites.count - 1) + 1)
            }
        }
        return (favorites, splits)
    }

    /// Adds to a profile's favorites the ones it doesn't already have; returns how many that was.
    @discardableResult
    func appendFavorites(_ new: [Bookmark], in profile: UUID) -> Int {
        var known = Set(favorites(in: profile).map { $0.url.absoluteString })
        let added = new.filter { known.insert($0.url.absoluteString).inserted }
        favorites += added
        for favorite in added { directory.assign(favorite: favorite.id, to: profile) }
        commit()
        return added.count
    }

    func spaceID(ofBookmark id: UUID) -> UUID? {
        spaces.first { $0.bookmarks.contains { $0.id == id } }?.id
    }

    /// Where something asked for at `index` goes in a list of `count`: the end when no place is given, and never
    /// before the start or past the end (an extension can ask for any number).
    nonisolated static func place(_ index: Int?, among count: Int) -> Int { max(0, min(index ?? count, count)) }

    @discardableResult
    func addBookmark(url: URL, title: String, icon: String? = nil, to spaceID: UUID, at index: Int? = nil, id: UUID = UUID()) -> Bookmark? {
        guard let s = self.index(of: spaceID) else { return nil }
        let bookmark = Bookmark(id: id, url: url, title: title, icon: icon)
        let at = Self.place(index, among: spaces[s].bookmarks.count)
        spaces[s].bookmarks.insert(bookmark, at: at)
        // Landing between a folder's pages doesn't put it in the folder: it goes just after, where the sidebar shows it.
        tidyFolders(s)
        commit()
        return bookmark
    }

    /// Many at the end of a space in one change (an import of thousands), saved and shown once.
    /// With `folders`, each page's folder path (outermost first): the folders are made, nested as they were, with the
    /// pages in them; a folder of the same name in the same place is used again.
    func appendBookmarks(_ new: [(url: URL, title: String)], to spaceID: UUID, folders paths: [[String]] = []) -> [Bookmark] {
        guard let s = self.index(of: spaceID), !new.isEmpty else { return [] }
        let added = new.map { Bookmark(id: UUID(), url: $0.url, title: $0.title) }
        spaces[s].bookmarks += added
        let folders = Self.filed(added.map(\.id), paths: paths, into: spaces[s].folders ?? [])
        if !folders.isEmpty { spaces[s].folders = folders }
        tidyFolders(s)
        commit()
        return added
    }

    /// Pages already in a space, each into the folder its path names (made if missing), in one change.
    func fileBookmarks(_ ids: [UUID], paths: [[String]], in spaceID: UUID) {
        guard let s = self.index(of: spaceID), !ids.isEmpty else { return }
        for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { ids.contains($0) } }
        let folders = Self.filed(ids, paths: paths, into: spaces[s].folders ?? [])
        if !folders.isEmpty { spaces[s].folders = folders }
        tidyFolders(s)
        commit()
    }

    /// How deep folders nest when they come over from another browser: as deep as people keep them there. A page
    /// deeper than this goes in the deepest of its folders that's kept.
    nonisolated static let folderDepthLimit = 8

    /// Puts pages in folders by their paths (outermost first), making the folders that aren't there yet, nested as
    /// the paths say; a folder of the same name in the same place is used again. Deeper than `folderDepthLimit`
    /// levels flattens.
    nonisolated static func filed(_ ids: [UUID], paths: [[String]], into existing: [BookmarkFolder]) -> [BookmarkFolder] {
        var folders = existing
        // Each folder by where it is and its name, so thousands of pages find theirs without a search each.
        struct Place: Hashable { let parent: UUID?; let name: String }
        var known = Dictionary(folders.indices.map { (Place(parent: folders[$0].parentID, name: folders[$0].name), $0) }, uniquingKeysWith: { a, _ in a })
        func folder(_ path: ArraySlice<String>, parent: UUID?) -> Int? {
            guard let name = path.first else { return nil }
            let at = known[Place(parent: parent, name: name)] ?? {
                var made = BookmarkFolder(name: name)
                made.parentID = parent
                // Shut: a big import of open folders is a long list to scroll (#343).
                made.isOpen = false
                folders.append(made)
                known[Place(parent: parent, name: name)] = folders.count - 1
                return folders.count - 1
            }()
            return path.count == 1 ? at : folder(path.dropFirst(), parent: folders[at].id)
        }
        for (id, path) in zip(ids, paths) where !path.isEmpty {
            if let f = folder(path.prefix(folderDepthLimit), parent: nil) { folders[f].bookmarkIDs.append(id) }
        }
        return folders
    }

    func removeBookmark(_ id: UUID) { removeBookmarks([id]) }

    /// Several at once, in one change (both pages of a pinned split).
    func removeBookmarks(_ ids: [UUID]) {
        favorites.removeAll { ids.contains($0.id) }
        tidyFavorites()
        for s in spaces.indices { spaces[s].bookmarks.removeAll { ids.contains($0.id) }; tidyFolders(s) }
        commit()
    }

    func updateBookmark(_ id: UUID, title: String? = nil, url: URL? = nil) {
        if let f = favorites.firstIndex(where: { $0.id == id }) {
            if let title { favorites[f].title = title }
            if let url { favorites[f].url = url }
        }
        for s in spaces.indices {
            if let b = spaces[s].bookmarks.firstIndex(where: { $0.id == id }) {
                if let title { spaces[s].bookmarks[b].title = title }
                if let url { spaces[s].bookmarks[b].url = url }
            }
        }
        commit()
    }

    /// A pinned page's or favorite's own icon (an SF Symbol's name, or an emoji); nil: its site's again.
    func setIcon(_ icon: String?, forBookmark id: UUID) {
        if Self.setting(icon, forBookmark: id, favorites: &favorites, spaces: &spaces) { commit() }
    }

    /// Gives the page with this id the icon wherever it's kept, a favorite or a space's pinned page. False when
    /// nothing changed: it's not there, or already has that icon.
    nonisolated static func setting(_ icon: String?, forBookmark id: UUID, favorites: inout [Bookmark], spaces: inout [SpaceInfo]) -> Bool {
        var changed = false
        for f in favorites.indices where favorites[f].id == id && favorites[f].icon != icon {
            favorites[f].icon = icon
            changed = true
        }
        for s in spaces.indices {
            for b in spaces[s].bookmarks.indices where spaces[s].bookmarks[b].id == id && spaces[s].bookmarks[b].icon != icon {
                spaces[s].bookmarks[b].icon = icon
                changed = true
            }
        }
        return changed
    }

    /// Moves a pinned page to a place in a space's list. `folder`: the folder it lands in (nil: none); when left
    /// out, it keeps the folder it's in if it stays in the same space. Half of a pinned split moves the pair.
    func moveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?? = .none) {
        guard bookmark(id) != nil, let target = self.index(of: spaceID) else { return }
        let from = self.spaceID(ofBookmark: id)
        let pinned = pinnedSplit(containing: id)
        let ids = pinned.map(\.ids) ?? [id]
        let moving = ids.compactMap(bookmark)
        for s in spaces.indices { spaces[s].bookmarks.removeAll { ids.contains($0.id) } }
        let at = max(0, min(index, spaces[target].bookmarks.count))
        spaces[target].bookmarks.insert(contentsOf: moving, at: at)
        let keep: UUID? = from == spaceID ? folderID(containing: id) : nil
        let landsIn: UUID? = switch folder { case .some(let chosen): chosen; case .none: keep }
        for s in spaces.indices {
            for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { ids.contains($0) } }
        }
        if let landsIn, let f = spaces[target].folders?.firstIndex(where: { $0.id == landsIn }) {
            // In the folder at the place it was dropped, by the list's order.
            spaces[target].folders?[f].bookmarkIDs.append(contentsOf: ids)
        }
        // Into another space, the pair stays a pair there.
        if let pinned, let from, let s = self.index(of: from), s != target {
            spaces[s].pinnedSplits?.removeAll { $0 == pinned }
            spaces[target].pinnedSplits = (spaces[target].pinnedSplits ?? []) + [pinned]
        }
        tidyFolders(target, keepingPlaceOf: id)
        if let from, let s = self.index(of: from), s != target { tidyFolders(s) }
        commit()
    }

    // MARK: Folders

    func folders(in spaceID: UUID) -> [BookmarkFolder] { space(spaceID)?.folders ?? [] }

    func folder(_ id: UUID) -> BookmarkFolder? {
        for space in spaces { if let f = space.folders?.first(where: { $0.id == id }) { return f } }
        return nil
    }

    func folderID(containing bookmarkID: UUID) -> UUID? {
        for space in spaces { if let f = space.folders?.first(where: { $0.bookmarkIDs.contains(bookmarkID) }) { return f.id } }
        return nil
    }

    private func spaceIndex(ofFolder id: UUID) -> Int? { spaces.firstIndex { $0.folders?.contains { $0.id == id } == true } }

    /// Every pinned page in a folder and its subfolders, in the list's order.
    func allBookmarkIDs(inFolder id: UUID) -> [UUID] {
        guard let s = spaceIndex(ofFolder: id) else { return [] }
        return (spaces[s].folders ?? []).pages(in: id, ordered: spaces[s].bookmarks.map(\.id))
    }

    /// Every folder inside this one, at any depth.
    func subfolderIDs(of id: UUID) -> [UUID] {
        guard let s = spaceIndex(ofFolder: id) else { return [] }
        return (spaces[s].folders ?? []).descendants(of: id)
    }

    /// How many folders a folder sits inside.
    func depth(ofFolder id: UUID) -> Int {
        guard let s = spaceIndex(ofFolder: id) else { return 0 }
        return (spaces[s].folders ?? []).depth(of: id)
    }

    /// A new folder in a space, holding these pinned pages (gathered where the first of them is). `parent`: the
    /// folder it goes in; left out, it goes in the folder its pages share, if they all share one.
    @discardableResult
    func addFolder(named name: String, with bookmarkIDs: [UUID], in spaceID: UUID, parent: UUID?? = .none) -> BookmarkFolder? {
        guard let s = self.index(of: spaceID) else { return nil }
        let members = spaces[s].bookmarks.map(\.id).filter { bookmarkIDs.contains($0) }
        let shared: UUID? = {
            let homes = Set(members.map { id in spaces[s].folders?.first { $0.bookmarkIDs.contains(id) }?.id })
            return homes.count == 1 ? homes.first ?? nil : nil
        }()
        let inside: UUID? = switch parent { case .some(let chosen): chosen; case .none: shared }
        for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { members.contains($0) } }
        var folder = BookmarkFolder(name: name, bookmarkIDs: members)
        if let inside, spaces[s].folders?.contains(where: { $0.id == inside }) == true {
            folder.parentID = inside
            // Open on the way in, so the new folder shows.
            if let p = spaces[s].folders?.firstIndex(where: { $0.id == inside }) { spaces[s].folders?[p].isOpen = true; spaces[s].folders?[p].tucked = nil }
        }
        spaces[s].folders = (spaces[s].folders ?? []) + [folder]
        tidyFolders(s)
        commit()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let s = spaceIndex(ofFolder: id), let f = spaces[s].folders?.firstIndex(where: { $0.id == id }) else { return }
        spaces[s].folders?[f].name = name
        commit()
    }

    func setIcon(_ icon: String?, forFolder id: UUID) {
        guard let s = spaceIndex(ofFolder: id), let f = spaces[s].folders?.firstIndex(where: { $0.id == id }),
              spaces[s].folders?[f].icon != icon else { return }
        spaces[s].folders?[f].icon = icon
        commit()
    }

    /// Opens or shuts a folder. Shut, it keeps `tucking` (its pages open now) hidden with the rest.
    func setFolderOpen(_ id: UUID, _ open: Bool, tucking: Set<UUID> = []) {
        guard let s = spaceIndex(ofFolder: id), let f = spaces[s].folders?.firstIndex(where: { $0.id == id }) else { return }
        spaces[s].folders?[f].isOpen = open
        spaces[s].folders?[f].tucked = open || tucking.isEmpty ? nil : tucking.sorted { $0.uuidString < $1.uuidString }
        commit()
    }

    /// Opens or shuts a folder and all its subfolders; shutting hides their pages in `shown`.
    func setFolderTreeOpen(_ id: UUID, _ open: Bool, shown: Set<UUID> = []) {
        guard let s = spaceIndex(ofFolder: id), let folders = spaces[s].folders else { return }
        spaces[s].folders = folders.folding(id, open: open, shown: shown)
        commit()
    }

    /// Opens or shuts every folder in a space; shutting hides their pages in `shown`.
    func setAllFoldersOpen(in spaceID: UUID, _ open: Bool, shown: Set<UUID> = []) {
        guard let s = self.index(of: spaceID), let folders = spaces[s].folders,
              folders.contains(where: { $0.isOpen != open }) else { return }
        spaces[s].folders = folders.folding(Set(folders.map(\.id)), open: open, shown: shown)
        commit()
    }

    /// A page opened again: it shows under its shut folder from now on, as any page opened there does.
    func untuck(_ bookmarkID: UUID) {
        var changed = false
        for s in spaces.indices {
            for f in (spaces[s].folders ?? []).indices where spaces[s].folders?[f].tucked?.contains(bookmarkID) == true {
                spaces[s].folders?[f].tucked?.removeAll { $0 == bookmarkID }
                if spaces[s].folders?[f].tucked?.isEmpty == true { spaces[s].folders?[f].tucked = nil }
                changed = true
            }
        }
        if changed { commit() }
    }

    /// The folder goes; what was in it (pages and folders) stays where it was, one level up.
    func removeFolder(_ id: UUID) {
        guard let s = spaceIndex(ofFolder: id), let gone = spaces[s].folders?.first(where: { $0.id == id }) else { return }
        for f in (spaces[s].folders ?? []).indices where spaces[s].folders?[f].parentID == id {
            spaces[s].folders?[f].parentID = gone.parentID
        }
        if let parent = gone.parentID, let p = spaces[s].folders?.firstIndex(where: { $0.id == parent }) {
            spaces[s].folders?[p].bookmarkIDs.append(contentsOf: gone.bookmarkIDs)
        }
        spaces[s].folders?.removeAll { $0.id == id }
        tidyFolders(s)
        commit()
    }

    /// Moves a folder, with everything inside it, to a place in a space's list, counted in pinned pages without its
    /// own. `parent`: the folder it goes into (nil: the top level); left out, it stays in the one it's in when it stays
    /// in its space. At the top level it never lands between another folder's pages or a pinned split's two; its own
    /// pinned splits go along.
    func moveFolder(_ id: UUID, to index: Int, in spaceID: UUID, parent: UUID?? = .none) {
        guard let s = spaceIndex(ofFolder: id), let target = self.index(of: spaceID),
              let f = spaces[s].folders?.firstIndex(where: { $0.id == id }), var folder = spaces[s].folders?[f] else { return }
        let inner = (spaces[s].folders ?? []).descendants(of: id)
        // Never into itself or a folder inside it, and only into a folder of the space it lands in.
        var into: UUID? = switch parent { case .some(let chosen): chosen; case .none: s == target ? folder.parentID : nil }
        if let p = into, p == id || inner.contains(p) || spaces[target].folders?.contains(where: { $0.id == p }) != true { into = folder.parentID.flatMap { s == target ? $0 : nil } }
        // Into a folder with no place given: at the end of that folder's pages, or where it sits if it has none.
        var at = into == nil ? folderDropIndex(index, moving: id, in: spaceID) : index
        if let p = into, index == Int.max {
            let members = (spaces[target].folders ?? []).pages(in: id)
            let others = spaces[target].bookmarks.filter { !members.contains($0.id) }
            let inside = (spaces[target].folders ?? []).pages(in: p)
            if let last = others.lastIndex(where: { inside.contains($0.id) }) { at = last + 1 }
            else {
                at = insertionIndex(intoEmptyFolder: p, space: target)
                // Counted without the moving folder's own pages, as `index` is.
                at -= spaces[target].bookmarks.prefix(at).filter { members.contains($0.id) }.count
            }
        }
        let members = (spaces[s].folders ?? []).pages(in: id)
        let moving = spaces[s].bookmarks.filter { members.contains($0.id) }
        spaces[s].bookmarks.removeAll { members.contains($0.id) }
        spaces[target].bookmarks.insert(contentsOf: moving, at: max(0, min(at, spaces[target].bookmarks.count)))
        folder.parentID = into
        spaces[s].folders?[f] = folder
        if let p = into, let pi = spaces[target].folders?.firstIndex(where: { $0.id == p }) { spaces[target].folders?[pi].isOpen = true; spaces[target].folders?[pi].tucked = nil }
        if s != target {
            // Its subfolders go along.
            let travelling = Set([id] + inner)
            let carried = (spaces[s].folders ?? []).filter { travelling.contains($0.id) }
            spaces[s].folders?.removeAll { travelling.contains($0.id) }
            spaces[target].folders = (spaces[target].folders ?? []) + carried
            let splits = spaces[s].pinnedSplits?.filter { members.contains($0.left) } ?? []
            spaces[s].pinnedSplits?.removeAll { members.contains($0.left) }
            if spaces[s].pinnedSplits?.isEmpty == true { spaces[s].pinnedSplits = nil }
            if !splits.isEmpty { spaces[target].pinnedSplits = (spaces[target].pinnedSplits ?? []) + splits }
            tidyFolders(s)
        }
        tidyFolders(target)
        commit()
    }

    /// Where a folder dropped at `index` in a space's list lands (see `moveFolder`).
    func folderDropIndex(_ index: Int, moving folderID: UUID, in spaceID: UUID) -> Int {
        guard let space = space(spaceID) else { return index }
        let all = space.folders ?? []
        let moving = all.pages(in: folderID)
        let travelling = Set([folderID] + all.descendants(of: folderID))
        return Self.folderDropIndex(index, in: space.bookmarks.map(\.id).filter { !moving.contains($0) },
                                    folders: all.filter { !travelling.contains($0.id) }, splits: space.pinnedSplits ?? [])
    }

    /// Between pages that belong together (one folder's, or a pinned split's two), a folder goes to the nearer end.
    nonisolated static func folderDropIndex(_ index: Int, in ids: [UUID], folders: [BookmarkFolder], splits: [PinnedSplit]) -> Int {
        // A page belongs to its outermost folder: a folder at the top level never lands inside another's subfolders.
        func root(_ id: UUID) -> UUID {
            var current = id, seen: Set<UUID> = [id]
            while let parent = folders.first(where: { $0.id == current })?.parentID, seen.insert(parent).inserted { current = parent }
            return current
        }
        var group: [UUID: UUID] = [:]
        for folder in folders { let r = root(folder.id); for id in folder.bookmarkIDs { group[id] = r } }
        for split in splits where group[split.left] == nil { for id in split.ids { group[id] = split.left } }
        let at = max(0, min(index, ids.count))
        guard at > 0, at < ids.count, let g = group[ids[at - 1]], group[ids[at]] == g else { return at }
        var start = at, end = at
        while start > 0, group[ids[start - 1]] == g { start -= 1 }
        while end < ids.count, group[ids[end]] == g { end += 1 }
        return at - start <= end - at ? start : end
    }

    /// Puts a pinned page in a folder of its space (at the end of it), or takes it out of any folder (nil).
    func setFolder(of bookmarkID: UUID, to folderID: UUID?) {
        // A pinned split goes in as one: its first page leads, and the rest follow it there.
        let bookmarkID = pinnedSplit(containing: bookmarkID)?.left ?? bookmarkID
        guard let s = spaces.firstIndex(where: { $0.bookmarks.contains { $0.id == bookmarkID } }) else { return }
        for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { $0 == bookmarkID } }
        if let folderID, let f = spaces[s].folders?.firstIndex(where: { $0.id == folderID }) {
            // An empty folder sits at the top of where it is: its first page goes there with it, at the top of the
            // pins, or at the start of its parent folder's pages.
            if (spaces[s].folders ?? []).pages(in: folderID).isEmpty, let from = spaces[s].bookmarks.firstIndex(where: { $0.id == bookmarkID }) {
                let page = spaces[s].bookmarks.remove(at: from)
                spaces[s].bookmarks.insert(page, at: insertionIndex(intoEmptyFolder: folderID, space: s))
            }
            // To the end of the folder: after its last page in the list.
            spaces[s].folders?[f].bookmarkIDs.append(bookmarkID)
            if let last = spaces[s].folders?[f].bookmarkIDs.dropLast().compactMap({ id in spaces[s].bookmarks.firstIndex { $0.id == id } }).max(),
               let from = spaces[s].bookmarks.firstIndex(where: { $0.id == bookmarkID }) {
                let bookmark = spaces[s].bookmarks.remove(at: from)
                spaces[s].bookmarks.insert(bookmark, at: min(from < last ? last : last + 1, spaces[s].bookmarks.count))
            }
        }
        tidyFolders(s)
        commit()
    }

    /// Where a page goes to be the first one in an empty folder: the top of the pins, or the start of its parent's pages
    /// (the parent's own place, for a parent that's empty too).
    private func insertionIndex(intoEmptyFolder id: UUID, space s: Int) -> Int {
        let folders = spaces[s].folders ?? []
        var parent = folders.first { $0.id == id }?.parentID
        while let p = parent {
            let inside = folders.pages(in: p)
            if let at = spaces[s].bookmarks.firstIndex(where: { inside.contains($0.id) }) { return at }
            parent = folders.first { $0.id == p }?.parentID
        }
        return 0
    }

    /// Keeps folders honest: only pages still in the space, and each folder's pages side by side in the list, where
    /// its first page is (or, for `keeping`, around the page just moved, so a drop lands where it was dropped).
    /// Pinned splits too: each keeps both its pages, side by side, or ends.
    private func tidyFolders(_ s: Int, keepingPlaceOf moved: UUID? = nil) {
        let folders = spaces[s].folders ?? [], splits = spaces[s].pinnedSplits ?? []
        guard !folders.isEmpty || !splits.isEmpty else { return }
        let tidy = Self.tidied(spaces[s].bookmarks, folders, splits)
        spaces[s].bookmarks = tidy.bookmarks
        if spaces[s].folders != nil { spaces[s].folders = tidy.folders }
        spaces[s].pinnedSplits = tidy.splits.isEmpty ? nil : tidy.splits
    }

    /// The rule behind pinned splits, on its own so it can be checked: a split keeps different pages that are in the
    /// list and in no other split, each just after the one before it (its first page leads), in the same folder.
    nonisolated static func tidied(_ bookmarks: [Bookmark], _ folders: [BookmarkFolder], _ splits: [PinnedSplit])
        -> (bookmarks: [Bookmark], folders: [BookmarkFolder], splits: [PinnedSplit]) {
        let ids = Set(bookmarks.map(\.id))
        var paired: Set<UUID> = []
        let kept = splits.filter { split in
            let pages = split.ids
            guard Set(pages).count == pages.count, pages.allSatisfy(ids.contains), paired.isDisjoint(with: pages) else { return false }
            paired.formUnion(pages)
            return true
        }
        var list = bookmarks
        var folders = folders
        for split in kept {
            for (previous, id) in zip(split.ids, split.riders) {
                guard let from = list.firstIndex(where: { $0.id == id }) else { continue }
                let page = list.remove(at: from)
                list.insert(page, at: (list.firstIndex { $0.id == previous } ?? list.count - 1) + 1)
                for f in folders.indices {
                    folders[f].bookmarkIDs.removeAll { $0 == id }
                    if folders[f].bookmarkIDs.contains(split.left) { folders[f].bookmarkIDs.append(id) }
                }
            }
        }
        let (tidyList, tidyFolders) = tidied(list, folders)
        return (tidyList, tidyFolders, kept)
    }

    // MARK: Pinned splits

    func pinnedSplits(in spaceID: UUID) -> [PinnedSplit] { space(spaceID)?.pinnedSplits ?? [] }

    /// The pinned split a pinned page is half of, if any.
    func pinnedSplit(containing bookmarkID: UUID) -> PinnedSplit? {
        if let split = favoriteSplits.first(where: { $0.contains(bookmarkID) }) { return split }
        for space in spaces { if let split = space.pinnedSplits?.first(where: { $0.contains(bookmarkID) }) { return split } }
        return nil
    }

    /// The folder a pinned tab group (#209) became, if the page is in one.
    func pinnedGroup(containing bookmarkID: UUID) -> BookmarkFolder? {
        for space in spaces {
            if let folder = space.folders?.first(where: { $0.groupID != nil && $0.bookmarkIDs.contains(bookmarkID) }) { return folder }
        }
        return nil
    }

    /// Pins the pages of a split view or tile group together at a place in a space's list, laid out as `layout`
    /// (whose pages are `marks`, in order), in one change.
    func addPinnedSplit(_ marks: [Bookmark], as layout: PinnedSplit, to spaceID: UUID, at index: Int? = nil) {
        guard let s = self.index(of: spaceID), marks.map(\.id) == layout.ids else { return }
        let at = Self.place(index, among: spaces[s].bookmarks.count)
        spaces[s].bookmarks.insert(contentsOf: marks, at: at)
        spaces[s].pinnedSplits = (spaces[s].pinnedSplits ?? []) + [layout]
        tidyFolders(s)
        commit()
    }

    /// Pages already pinned in a space become these splits, in one change; any that don't hold together are left out.
    func addPinnedSplits(_ layouts: [PinnedSplit], in spaceID: UUID) {
        guard let s = self.index(of: spaceID), !layouts.isEmpty else { return }
        spaces[s].pinnedSplits = (spaces[s].pinnedSplits ?? []) + layouts
        tidyFolders(s)
        commit()
    }

    /// Pins a tab group (#209) as one folder, keeping its name and fold state.
    func addPinnedGroup(_ marks: [Bookmark], splits: [PinnedSplit] = [], named name: String, group: UUID, isOpen: Bool, to spaceID: UUID, at index: Int? = nil) {
        guard let s = self.index(of: spaceID), !marks.isEmpty else { return }
        let at = Self.place(index, among: spaces[s].bookmarks.count)
        spaces[s].bookmarks.insert(contentsOf: marks, at: at)
        var folder = BookmarkFolder(name: name, bookmarkIDs: marks.map(\.id))
        folder.groupID = group
        folder.isOpen = isOpen
        // A folded group hides its pages while open.
        if !isOpen { folder.tucked = marks.map(\.id).sorted { $0.uuidString < $1.uuidString } }
        spaces[s].folders = (spaces[s].folders ?? []) + [folder]
        if !splits.isEmpty { spaces[s].pinnedSplits = (spaces[s].pinnedSplits ?? []) + splits }
        tidyFolders(s)
        commit()
    }

    /// Moves a pinned page beside another of the same space as a pinned split, in that one's place and folder.
    func joinPinned(_ id: UUID, beside pinnedID: UUID, onRight: Bool) {
        guard let s = spaces.firstIndex(where: { $0.bookmarks.contains { $0.id == pinnedID } }),
              let page = spaces[s].bookmarks.first(where: { $0.id == id }) else { return }
        spaces[s].bookmarks.removeAll { $0.id == id }
        for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { $0 == id } }
        pinBeside(page, pinnedID, onRight: onRight)
    }

    /// Pins a new page beside a pinned one as a pinned split, in its place and its folder.
    func pinBeside(_ page: Bookmark, _ pinnedID: UUID, onRight: Bool) {
        guard let s = spaces.firstIndex(where: { $0.bookmarks.contains { $0.id == pinnedID } }),
              let at = spaces[s].bookmarks.firstIndex(where: { $0.id == pinnedID }) else { return }
        spaces[s].bookmarks.insert(page, at: onRight ? at + 1 : at)
        spaces[s].pinnedSplits = (spaces[s].pinnedSplits ?? []) + [onRight ? PinnedSplit(left: pinnedID, right: page.id) : PinnedSplit(left: page.id, right: pinnedID)]
        // The split's right page follows its left one into the folder.
        if !onRight, let f = spaces[s].folders?.firstIndex(where: { $0.bookmarkIDs.contains(pinnedID) }),
           let i = spaces[s].folders?[f].bookmarkIDs.firstIndex(of: pinnedID) {
            spaces[s].folders?[f].bookmarkIDs[i] = page.id
        }
        tidyFolders(s)
        commit()
    }

    /// A page into the pinned split `targetID` is in, where `drop` puts it (`SplitPair.adding`), after the split's
    /// pages and in its folder: a new page, or one pinned on its own in that space.
    func joinPinnedSplit(_ page: Bookmark, onto targetID: UUID, _ drop: TileDrop.Kind) {
        guard let s = spaces.firstIndex(where: { $0.pinnedSplits?.contains { $0.contains(targetID) } == true }),
              let i = spaces[s].pinnedSplits?.firstIndex(where: { $0.contains(targetID) }),
              let grown = spaces[s].pinnedSplits?[i].layout.adding(page.id, drop) else { return }
        spaces[s].bookmarks.removeAll { $0.id == page.id }
        for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { $0 == page.id } }
        let after = spaces[s].bookmarks.lastIndex { grown.contains($0.id) }.map { $0 + 1 } ?? spaces[s].bookmarks.count
        spaces[s].bookmarks.insert(page, at: after)
        if let f = spaces[s].folders?.firstIndex(where: { $0.bookmarkIDs.contains(targetID) }) { spaces[s].folders?[f].bookmarkIDs.append(page.id) }
        spaces[s].pinnedSplits?[i] = PinnedSplit(layout: grown)
        tidyFolders(s)
        commit()
    }

    /// One page out of its pinned or favorite group of three or four: it stays where it's kept, on its own after the
    /// group, and the rest close up around its place as a group of tabs does; out of a split of two, the split ends.
    func removeFromPinnedSplit(_ id: UUID) {
        func shrunk(_ split: PinnedSplit) -> PinnedSplit? { split.layout.removing(id).map(PinnedSplit.init(layout:)) }
        if let i = favoriteSplits.firstIndex(where: { $0.contains(id) }) {
            if let rest = shrunk(favoriteSplits[i]) { favoriteSplits[i] = rest } else { favoriteSplits.remove(at: i) }
            tidyFavorites()
            commit()
            return
        }
        guard let s = spaces.firstIndex(where: { $0.pinnedSplits?.contains { $0.contains(id) } == true }),
              let i = spaces[s].pinnedSplits?.firstIndex(where: { $0.contains(id) }), let split = spaces[s].pinnedSplits?[i] else { return }
        if let rest = shrunk(split) { spaces[s].pinnedSplits?[i] = rest } else { spaces[s].pinnedSplits?.remove(at: i) }
        if spaces[s].pinnedSplits?.isEmpty == true { spaces[s].pinnedSplits = nil }
        tidyFolders(s)
        commit()
    }

    /// Ends a pinned split; both pages stay pinned where they are.
    func removePinnedSplit(containing bookmarkID: UUID) {
        if favoriteSplits.contains(where: { $0.contains(bookmarkID) }) {
            favoriteSplits.removeAll { $0.contains(bookmarkID) }
            commit()
            return
        }
        guard let s = spaces.firstIndex(where: { $0.pinnedSplits?.contains { $0.contains(bookmarkID) } == true }) else { return }
        spaces[s].pinnedSplits?.removeAll { $0.contains(bookmarkID) }
        if spaces[s].pinnedSplits?.isEmpty == true { spaces[s].pinnedSplits = nil }
        commit()
    }

    /// How an open pinned split was last laid out, so it opens that way again. A swap (or a group's pages in a new
    /// order) trades their places in the list too; a new size, direction or place is only saved.
    func setPinnedSplitLayout(_ layout: PinnedSplit) {
        let pages = Set(layout.ids)
        if let i = favoriteSplits.firstIndex(where: { Set($0.ids) == pages }) {
            let swapped = favoriteSplits[i].ids != layout.ids
            favoriteSplits[i] = layout
            if swapped { tidyFavorites(); commit() } else { save() }
            return
        }
        for s in spaces.indices {
            guard let i = spaces[s].pinnedSplits?.firstIndex(where: { Set($0.ids) == pages }) else { continue }
            let swapped = spaces[s].pinnedSplits?[i].ids != layout.ids
            spaces[s].pinnedSplits?[i] = layout
            if swapped {
                tidyFolders(s)
                commit()
            } else {
                save()
            }
            return
        }
    }

    /// The rule behind folders, on its own so it can be checked: each folder keeps only pages that are in the list, in
    /// the list's order, and its pages sit together where its first one is; pages in no folder stay where they are.
    nonisolated static func tidied(_ bookmarks: [Bookmark], _ folders: [BookmarkFolder]) -> ([Bookmark], [BookmarkFolder]) {
        var folders = folders
        let ids = bookmarks.map(\.id)
        // Only pages that still exist, in the space's order, and each in one folder at most (the first that has it).
        var claimed: Set<UUID> = []
        for f in folders.indices {
            folders[f].bookmarkIDs = ids.filter { folders[f].bookmarkIDs.contains($0) && !claimed.contains($0) }
            claimed.formUnion(folders[f].bookmarkIDs)
        }
        // A folder's parent is a folder that's here, and never itself or one inside it.
        let known = Set(folders.map(\.id))
        for f in folders.indices {
            guard let parent = folders[f].parentID else { continue }
            var seen: Set<UUID> = [folders[f].id], p: UUID? = parent, loops = false
            while let q = p {
                if !known.contains(q) || !seen.insert(q).inserted { loops = true; break }
                p = folders.first { $0.id == q }?.parentID
            }
            if loops { folders[f].parentID = nil }
        }
        // Each level in the order its first page comes; an empty folder at the top of where it sits. Pages of a folder
        // and of all its subfolders end up side by side, each subfolder's inside its parent's.
        let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var folderOf: [UUID: UUID] = [:]
        for folder in folders { for id in folder.bookmarkIDs { folderOf[id] = folder.id } }
        var firstAt: [UUID: Int] = [:]
        func first(_ id: UUID) -> Int {
            if let known = firstAt[id] { return known }
            firstAt[id] = -1
            let own = folders.first { $0.id == id }?.bookmarkIDs.compactMap { position[$0] } ?? []
            let inner = folders.children(of: id).map { first($0.id) }.filter { $0 >= 0 }
            let at = (own + inner).min() ?? -1
            firstAt[id] = at
            return at
        }
        let byID = Dictionary(bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Bookmark] = []
        var placed: Set<UUID> = []
        var emitted: Set<UUID> = []
        func emit(_ parent: UUID?) {
            var units: [(at: Int, order: Int, page: UUID?, folder: UUID?)] = []
            for (i, id) in ids.enumerated() where folderOf[id] == parent { units.append((i, i, id, nil)) }
            for (i, folder) in folders.enumerated() where folder.parentID == parent { units.append((first(folder.id), ids.count + i, nil, folder.id)) }
            units.sort { ($0.at, $0.order) < ($1.at, $1.order) }
            for unit in units {
                if let page = unit.page, !placed.contains(page), let b = byID[page] { result.append(b); placed.insert(page) }
                if let folder = unit.folder, emitted.insert(folder).inserted { emit(folder) }
            }
        }
        emit(nil)
        // Anything a broken record left out still stays pinned, at the end.
        for bookmark in bookmarks where !placed.contains(bookmark.id) { result.append(bookmark) }
        for f in folders.indices { folders[f].bookmarkIDs = result.map(\.id).filter { folders[f].bookmarkIDs.contains($0) } }
        return (result, folders)
    }

    /// Spaces, bookmarks and favorites as they are now, for undo.
    struct Snapshot: Equatable {
        fileprivate let siteRoutes: [SiteRoutes.Route]
        fileprivate let spaces: [SpaceInfo]
        fileprivate let favorites: [Bookmark]
        fileprivate let favoriteSplits: [PinnedSplit]
        /// Which space was on which profile: moving a space to another profile can be undone. The profiles
        /// themselves aren't kept: making or removing one isn't undone.
        fileprivate let spaceProfiles: ProfileDirectory.Assignments
        var spaceIDs: Set<UUID> { Set(spaces.map(\.id)) }
    }

    var snapshot: Snapshot {
        Snapshot(siteRoutes: siteRoutes, spaces: spaces, favorites: favorites, favoriteSplits: favoriteSplits, spaceProfiles: directory.assignments)
    }

    func restore(_ snapshot: Snapshot) {
        siteRoutes = snapshot.siteRoutes
        spaces = snapshot.spaces
        favorites = snapshot.favorites
        favoriteSplits = snapshot.favoriteSplits
        directory.restore(assignments: snapshot.spaceProfiles)
        commit()
    }

    // MARK: Profiles

    /// Every profile, the first one first.
    var profiles: [ProfileInfo] { directory.all }
    /// Whether there's more than the first profile: only then does anything in the window speak of profiles.
    var hasManyProfiles: Bool { directory.all.count > 1 }
    /// More than one profile besides AI Apps: where your spaces are listed under their profiles.
    var hasManyOfYourProfiles: Bool { directory.all.filter { !$0.isHeadless }.count > 1 }

    func profileID(ofSpace id: UUID) -> UUID { directory.profileID(ofSpace: id) }
    func spaces(in profile: UUID) -> [SpaceInfo] { spaces.filter { directory.profileID(ofSpace: $0.id) == profile } }
    /// Whether a space is on the AI Apps profile (Headless), kept out of your windows.
    func isAIAppsSpace(_ id: UUID) -> Bool { directory.headless.map { directory.profileID(ofSpace: id) == $0.id } ?? false }
    /// The spaces your windows list: all but the AI Apps profile's.
    var yourSpaces: [SpaceInfo] { directory.headless == nil ? spaces : spaces.filter { !isAIAppsSpace($0.id) } }

    /// The spaces under their profiles, in the profiles' order, for a list of places to go: a profile with none of
    /// them isn't there, and `excluding` (the space you're in) is left out.
    func spaceGroups(excluding: UUID? = nil) -> [(profile: ProfileInfo, spaces: [SpaceInfo])] {
        profiles.filter { !$0.isHeadless }.map { profile in (profile, spaces(in: profile.id).filter { $0.id != excluding }) }.filter { !$0.spaces.isEmpty }
    }

    @discardableResult
    func addProfile(name: String, color: SpaceColor? = nil) -> ProfileInfo {
        let info = directory.add(name: name, color: color)
        commit()
        return info
    }

    /// A profile of its own for a space, in one step (New Profile in a space's editor): named after the space, in
    /// its color when that's one a profile can have, else the next one no profile has. It starts with no extensions.
    @discardableResult
    func addProfile(forSpace id: UUID) -> ProfileInfo? {
        guard let space = space(id) else { return nil }
        let pick = ProfileDirectory.ownColor(for: space.color, used: profiles.map { color(of: $0) })
        let info = directory.addOwn(for: id, named: space.name, taken: profiles.map(\.displayName), color: pick)
        commit()
        return info
    }

    /// The space AI apps work in in the background: the AI Apps profile's. Both are made on first need (and again
    /// after you remove them), never twice.
    func headlessSpace() -> SpaceInfo {
        let used = profiles.map { color(of: $0) }
        let profile = directory.headless ?? directory.addHeadless(name: "AI Apps", color: SpaceColor.next(unused: used))
        // An existing space needs no save or signal. A new profile has no space yet, and making its space saves both.
        if let space = spaces(in: profile.id).first { return space }
        return addSpace(name: profile.displayName, color: profile.color, profile: profile.id)
    }

    /// A profile made for a space keeps its name while the space is being named: typed, the space's new name.
    func renameProfile(_ id: UUID, after spaceName: String) {
        guard let profile = directory.profile(id), !profile.isDefault, !profile.isHeadless else { return }
        let name = ProfileDirectory.freshName(spaceName, taken: profiles.filter { $0.id != id }.map(\.displayName))
        guard !name.isEmpty, name != profile.name else { return }
        directory.update(id, name: name, color: profile.color)
        commit()
    }

    /// Lists again a profile whose data is on disk under `id` but which is in no list (Profiles.orphans): it's a
    /// profile once more, with what it kept.
    @discardableResult
    func restoreProfile(_ id: UUID, name: String) -> ProfileInfo? {
        guard id != Profile.defaultID, directory.profile(id) == nil, !directory.deleting.contains(where: { $0.id == id }) else { return nil }
        let info = directory.add(name: name, id: id)
        commit()
        return info
    }

    /// Writes down that the data on disk under `id`, which is no profile's, is to be erased. False when that
    /// couldn't be written, or it's a profile's after all: nothing is then erased.
    func markForErasing(_ id: UUID) -> Bool {
        let before = directory
        directory.markForErasing(id)
        guard directory != before else { return false }
        saveNow()
        guard savedDirectory == directory else { directory = before; return false }
        return true
    }

    func updateProfile(_ id: UUID, name: String?, color: SpaceColor?) {
        directory.update(id, name: name, color: color)
        commit()
    }

    /// Puts a space on a profile. Its open pages are then rebuilt there (TabManager, on `changed`).
    func setProfile(_ profile: UUID, forSpace space: UUID) {
        guard directory.profileID(ofSpace: space) != profile else { return }
        directory.assign(space: space, to: profile)
        commit()
    }

    /// Takes a profile out of the list, leaving its data to be erased (Profiles). Its spaces move to the first
    /// profile (the AI Apps profile's go with it); its favorites go with it. Written at once: from here on, a
    /// removal that's interrupted is finished
    /// at the next start.
    ///
    /// False, with nothing changed, when that couldn't be written (a full disk): erasing its data then would leave
    /// a profile that comes back at the next start with its extensions and history gone.
    @discardableResult
    func removeProfile(_ id: UUID) -> Bool {
        guard let profile = directory.profile(id), !profile.isDefault else { return false }
        let before = (directory, favorites, favoriteSplits, spaces, siteRoutes)
        let gone = Set(favorites(in: id).map(\.id))
        favorites.removeAll { gone.contains($0.id) }
        tidyFavorites()
        // The AI Apps profile's spaces go with it, with routes to them, as removeSpace takes them.
        if profile.isHeadless, case let own = Set(spaces(in: id).map(\.id)), spaces.contains(where: { !own.contains($0.id) }) {
            spaces.removeAll { own.contains($0.id) }
            siteRoutes.removeAll { own.contains($0.spaceID) }
        }
        directory.remove(id)
        saveNow()
        guard savedDirectory == directory else {
            (directory, favorites, favoriteSplits, spaces, siteRoutes) = before
            return false
        }
        changed.send()
        return true
    }

    /// A removed profile's data is erased.
    func finishedRemovingProfile(_ id: UUID) {
        directory.finishedDeleting(id)
        saveNow()
    }

    /// At launch: spaces and favorites that are gone are forgotten. Not when the library couldn't be read and was
    /// set aside: put back, its spaces must find their profiles as they left them. A space that's gone but has
    /// archived tabs is remembered while it has them, so they stay its profile's.
    func pruneProfileAssignments() {
        guard wasRead else { return }
        directory.prune(keeping: Set(spaces.map(\.id)).union(TabArchive.shared.entries.map(\.spaceID)), favorites: Set(favorites.map(\.id)))
        save()
    }

    func appendSpaces(_ newSpaces: [SpaceInfo]) {
        spaces.append(contentsOf: newSpaces)
        commit()
    }
}

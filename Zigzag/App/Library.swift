import AppKit

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
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
}

extension Array where Element == BookmarkFolder {
    /// The folders directly inside `parent` (nil: the top level).
    nonisolated func children(of parent: UUID?) -> [BookmarkFolder] { filter { $0.parentID == parent } }

    /// Every folder inside `id`, at any depth.
    nonisolated func descendants(of id: UUID) -> [UUID] {
        var result: [UUID] = [], queue = [id]
        while let next = queue.popLast() {
            for child in children(of: next) where !result.contains(child.id) { result.append(child.id); queue.append(child.id) }
        }
        return result
    }

    /// Every pinned page in a folder or its subfolders.
    nonisolated func pages(in id: UUID) -> Set<UUID> {
        var ids = Set(first { $0.id == id }?.bookmarkIDs ?? [])
        for sub in descendants(of: id) { ids.formUnion(first { $0.id == sub }?.bookmarkIDs ?? []) }
        return ids
    }

    /// How many folders a folder is inside (0 at the top level).
    nonisolated func depth(of id: UUID) -> Int {
        var depth = 0, seen: Set<UUID> = [id]
        var parent = first { $0.id == id }?.parentID
        while let p = parent, seen.insert(p).inserted { depth += 1; parent = first { $0.id == p }?.parentID }
        return depth
    }
}

/// Two pinned pages that open side by side, as the split view they were pinned from. Its pages stay in the space's
/// own list, the right one just after the left, in the same folder.
struct PinnedSplit: Codable {
    var left: UUID
    var right: UUID
    /// Share of the width (or height, when vertical) the left page gets.
    var ratio = 0.5
    /// Stacked top and bottom instead of side by side.
    var vertical = false

    func contains(_ id: UUID) -> Bool { left == id || right == id }
}

/// The same pinned split pairs the same pages in the same order. Its size and direction are left out, so resizing it
/// doesn't count as changing the library, and ⌘Z for what came before still works.
extension PinnedSplit: Equatable {
    static func == (a: PinnedSplit, b: PinnedSplit) -> Bool { a.left == b.left && a.right == b.right }
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
    /// How much of its hue the color has, from 0 (none: white, a gray or black) to 1 (all of it). Nil: all.
    var tint: Double? = nil
    /// The second color's own tint. Nil: all of it.
    var tint2: Double? = nil
    /// How much of the desktop shows through the frame, from 0 (solid) to 1 (the most). Nil: solid.
    var translucency: Double? = nil
    /// False: frosted glass, milkier and softer. Nil or true: clear glass where the Mac has it (`usesClearGlass`).
    var clearGlass: Bool? = nil
    /// Whether this Mac has clear glass (Liquid Glass, macOS 26 and later).
    static var hasClearGlass: Bool { if #available(macOS 26.0, *) { true } else { false } }
    /// Clear glass, the default where the Mac has it; frosted when chosen, or before macOS 26.
    var usesClearGlass: Bool { Self.hasClearGlass && clearGlass != false && !PowerSaving.isOn }
    /// Shown beside its name and in the space switcher: an SF Symbol's name, or an emoji. Nil: a dot.
    var icon: String? = nil

    /// No hue of its own: white, a gray, or black.
    var isNeutral: Bool { (hue == nil && color.isNeutral) || (tint ?? 1) < 0.005 }
    /// How much of its hue the first color has, 0 for white, grays and black.
    var tintAmount: Double { isNeutral ? 0 : min(max(tint ?? 1, 0), 1) }
    var tintAmount2: Double { min(max(tint2 ?? 1, 0), 1) }

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
        if isNeutral { return color.isNeutral ? color.swatch : SpaceColor.graphite.swatch }
        return hue.map(SpaceColor.swatch(hue:)) ?? color.swatch
    }
    /// The hue the space is built on, curated or custom.
    var baseHue: Double { hue ?? color.hue }
    /// Where the gradient ends.
    var background2: NSColor? {
        hue2.map { h in
            if let depth = brightness2 ?? brightness { return SpaceColor.paint(hue: h, depth: depth, tint: tintAmount2) }
            return SpaceColor.background(hue: h, intensity: intensity2 ?? intensity ?? SpaceColor.defaultIntensity)
        }
    }
    var gradientAngle: Double { angle ?? 45 }

    /// The frame as the window lays it down: the color, thinned when see-through so the desktop shows under it.
    /// Over glass the color leans toward the space's strong version (its dot's) the more shows through, so a thin
    /// wash still reads as the space's color instead of gray.
    var frameColor: NSColor {
        guard isSeeThrough else { return background }
        return Self.covering(Self.richer(background, toward: swatch, by: isNeutral ? 0 : 0.6 * seeThrough), by: coverage)
    }
    var frameColor2: NSColor? {
        guard isSeeThrough else { return background2 }
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

    /// `color` at `alpha`, still following light and dark when it does.
    private static func covering(_ color: NSColor, by alpha: CGFloat) -> NSColor {
        guard alpha < 1 else { return color }
        return NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
            return resolved.withAlphaComponent(alpha)
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
        return space
    }

    /// Light or dark for the window: whichever text reads better on this space's own colors, judged at the
    /// harder end of a gradient. See-through spaces are judged the same way: the frosting under them follows the
    /// mode chosen, so it lands on the same side. Spaces that follow the Mac keep what they were given.
    var readableAppearance: String? {
        guard brightness != nil else {
            // White and black stay themselves day and night, so the window's mode stays with them, never black text on black.
            if appearance == nil, hue == nil, !isSeeThrough { if color == .ink { return "dark" }; if color == .snow { return "light" } }
            return appearance
        }
        let colors = [background] + (background2.map { [$0] } ?? [])
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

enum SearchEngine: String, Codable, CaseIterable {
    case google, duckDuckGo, brave, bing, kagi, ecosia, startpage, perplexity, yahoo, baidu, yandex, custom

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
        case .custom: Self.isValidTemplate(Self.customTemplate) ? (URL(string: Self.customTemplate.replacingOccurrences(of: "%s", with: "q"))?.host() ?? "Custom") : "Custom"
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
            let words = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? query
            if Self.isValidTemplate(template), let url = URL(string: template.replacingOccurrences(of: "%s", with: words)) { return url }
            return SearchEngine.google.searchURL(query)
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
        var favoriteSplits: [PinnedSplit]?
        var searchEngine: SearchEngine
        var importedFromArc: Bool?
    }

    private(set) var spaces: [SpaceInfo]
    /// Favorites: tiles at the top of the sidebar, the same in every space.
    private(set) var favorites: [Bookmark] = []
    /// Favorites kept together as a split view: one tile, two pages side by side. In `favorites` the right page
    /// follows the left.
    private(set) var favoriteSplits: [PinnedSplit] = []
    var searchEngine: SearchEngine { didSet { save() } }
    var importedFromArc: Bool { didSet { save() } }

    /// Fires whenever spaces or bookmarks change.
    let changed = Signal<Void>()

    private init() {
        if let stored = JSONStore.load(Stored.self, from: Paths.library), !stored.spaces.isEmpty {
            spaces = stored.spaces.map(\.upgraded)
            favorites = stored.favorites ?? []
            favoriteSplits = stored.favoriteSplits ?? []
            searchEngine = stored.searchEngine
            importedFromArc = stored.importedFromArc ?? false
        } else {
            spaces = [SpaceInfo(name: "Personal", color: .sky)]
            searchEngine = .google
            importedFromArc = false
            saveNow()
        }
    }

    private let saveDebouncer = Debouncer(delay: 0.5)

    func save() {
        saveDebouncer.call { [self] in saveNow() }
    }

    func saveNow() {
        saveDebouncer.cancel()
        JSONStore.save(Stored(spaces: spaces, favorites: favorites, favoriteSplits: favoriteSplits.isEmpty ? nil : favoriteSplits,
                              searchEngine: searchEngine, importedFromArc: importedFromArc), to: Paths.library)
    }

    private func commit() {
        save()
        changed.send()
    }

    // MARK: Spaces

    func space(_ id: UUID) -> SpaceInfo? { spaces.first { $0.id == id } }

    func index(of id: UUID) -> Int? { spaces.firstIndex { $0.id == id } }

    @discardableResult
    func addSpace(name: String? = nil, color: SpaceColor? = nil) -> SpaceInfo {
        let used = Set(spaces.map(\.color))
        let pick = color ?? SpaceColor.allCases.first { !$0.isNeutral && !used.contains($0) } ?? SpaceColor.allCases[spaces.count % SpaceColor.allCases.count]
        let space = SpaceInfo(name: name ?? "Space \(spaces.count + 1)", color: pick)
        spaces.append(space)
        commit()
        return space
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

    func setColor(_ color: SpaceColor, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].color = color
        spaces[i].hue = nil
        spaces[i].intensity = nil
        spaces[i].tint = nil
        commit()
    }

    func setAppearance(_ appearance: String?, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].appearance = appearance
        commit()
    }

    func setSecondHue(_ hue: Double?, intensity: Double? = nil, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].hue2 = hue.map { $0.truncatingRemainder(dividingBy: 1) }
        spaces[i].intensity2 = hue == nil ? nil : intensity ?? spaces[i].intensity2
        commit()
    }

    /// Everything about how a space looks, from the space editor, in one save.
    func setLook(_ look: SpaceInfo) {
        guard let i = index(of: look.id) else { return }
        spaces[i].color = look.color
        spaces[i].hue = look.hue
        spaces[i].intensity = look.intensity
        spaces[i].hue2 = look.hue2
        spaces[i].intensity2 = look.intensity2
        spaces[i].brightness = look.brightness
        spaces[i].brightness2 = look.brightness2
        spaces[i].angle = look.angle
        spaces[i].tint = look.tint
        spaces[i].tint2 = look.tint2
        spaces[i].translucency = look.translucency
        spaces[i].clearGlass = look.clearGlass
        spaces[i].glass = nil
        spaces[i].grain = look.grain
        spaces[i].appearance = look.appearance
        commit()
    }

    func setSecondBrightness(_ brightness: Double?, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].brightness2 = brightness
        commit()
    }

    func setGradientAngle(_ angle: Double, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].angle = angle
        commit()
    }

    /// Nil: automatic. Otherwise the window's mode follows it: light for the lighter half, dark for the darker.
    func setBrightness(_ brightness: Double?, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].brightness = brightness
        spaces[i].appearance = brightness.map { $0 < 0.5 ? "light" : "dark" }
        commit()
    }

    func setGrain(_ grain: Double, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].grain = grain > 0.01 ? min(grain, 1) : nil
        commit()
    }

    func setHue(_ hue: Double, intensity: Double? = nil, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].hue = hue
        spaces[i].tint = nil
        if let intensity { spaces[i].intensity = intensity }
        commit()
    }

    func removeSpace(_ id: UUID) {
        guard spaces.count > 1, let i = index(of: id) else { return }
        spaces.remove(at: i)
        commit()
    }

    /// Puts back a removed space, bookmarks and all, at its old place (undo).
    func insertSpace(_ space: SpaceInfo, at index: Int) {
        guard self.index(of: space.id) == nil else { return }
        spaces.insert(space, at: max(0, min(index, spaces.count)))
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

    /// The favorites as the grid shows them: one tile each, a split's two pages in one (its left page leads).
    var favoriteTiles: [(Bookmark, partner: Bookmark?)] {
        let rights = Set(favoriteSplits.map(\.right))
        let byID = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return favorites.filter { !rights.contains($0.id) }.map { favorite in
            (favorite, favoriteSplits.first { $0.left == favorite.id }.flatMap { byID[$0.right] })
        }
    }

    /// `slot` counts tiles, as the grid shows them; nil: at the end.
    @discardableResult
    func addFavorite(url: URL, title: String, at slot: Int? = nil, id: UUID = UUID()) -> Bookmark {
        let favorite = Bookmark(id: id, url: url, title: title)
        arrangeFavorites(Self.placing([id], atSlot: slot, in: favorites.map(\.id), splits: favoriteSplits), adding: [favorite])
        commit()
        return favorite
    }

    /// Two pages as one favorite, side by side, at a tile's place.
    func addFavoriteSplit(_ left: Bookmark, _ right: Bookmark, at slot: Int? = nil, ratio: Double = 0.5, vertical: Bool = false) {
        favoriteSplits.removeAll { $0.contains(left.id) || $0.contains(right.id) }
        arrangeFavorites(Self.placing([left.id, right.id], atSlot: slot, in: favorites.map(\.id), splits: favoriteSplits), adding: [left, right])
        var split = PinnedSplit(left: left.id, right: right.id)
        split.ratio = ratio
        split.vertical = vertical
        favoriteSplits.append(split)
        tidyFavorites()
        commit()
    }

    /// A page (a favorite, or one becoming one) joins the favorite `targetID`: the two become one split favorite where
    /// that favorite's tile is, the page on the right or the left.
    func joinFavorite(_ page: Bookmark, onto targetID: UUID, onRight: Bool) {
        guard let target = favorites.first(where: { $0.id == targetID }), page.id != targetID else { return }
        let (left, right) = onRight ? (target, page) : (page, target)
        favoriteSplits.removeAll { $0.contains(left.id) || $0.contains(right.id) }
        arrangeFavorites(Self.placing([left.id, right.id], at: targetID, in: favorites.map(\.id)), adding: [page])
        favoriteSplits.append(PinnedSplit(left: left.id, right: right.id))
        tidyFavorites()
        commit()
    }

    /// Moves a favorite (and its split's other page with it) to a tile's place.
    func moveFavorite(_ id: UUID, to slot: Int) {
        guard isFavorite(id) else { return }
        let ids = favoriteSplits.first { $0.contains(id) }.map { [$0.left, $0.right] } ?? [id]
        arrangeFavorites(Self.placing(ids, atSlot: slot, in: favorites.map(\.id), splits: favoriteSplits))
        commit()
    }

    /// Puts the favorites (and any new ones) in this order.
    private func arrangeFavorites(_ order: [UUID], adding new: [Bookmark] = []) {
        let byID = Dictionary((favorites + new).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        favorites = order.compactMap { byID[$0] }
    }

    /// The favorites' ids with `moving` (one tile's pages) put before the tile at `slot` among the rest, or after the
    /// last (nil, or past the end). A split's right page doesn't count as a tile of its own.
    nonisolated static func placing(_ moving: [UUID], atSlot slot: Int?, in ids: [UUID], splits: [PinnedSplit]) -> [UUID] {
        let rights = Set(splits.map(\.right))
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
    /// Half of a pinned split brings the other half: they stay one split, now a favorite.
    func makeFavorite(_ bookmarkID: UUID, at slot: Int? = nil) {
        guard let bookmark = bookmark(bookmarkID), !isFavorite(bookmarkID) else { return }
        if let pinned = pinnedSplit(containing: bookmarkID), let left = self.bookmark(pinned.left), let right = self.bookmark(pinned.right) {
            for s in spaces.indices {
                spaces[s].bookmarks.removeAll { pinned.contains($0.id) }
                spaces[s].pinnedSplits?.removeAll { $0.contains(bookmarkID) }
                if spaces[s].pinnedSplits?.isEmpty == true { spaces[s].pinnedSplits = nil }
                tidyFolders(s)
            }
            arrangeFavorites(Self.placing([left.id, right.id], atSlot: slot, in: favorites.map(\.id), splits: favoriteSplits), adding: [left, right])
            favoriteSplits.append(pinned)
            tidyFavorites()
            commit()
            return
        }
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == bookmarkID }; tidyFolders(s) }
        arrangeFavorites(Self.placing([bookmarkID], atSlot: slot, in: favorites.map(\.id), splits: favoriteSplits), adding: [bookmark])
        commit()
    }

    /// A favorite moved down among a space's pinned tabs, at a place in its list; a split favorite becomes a pinned
    /// split there.
    func pinFavorite(_ id: UUID, in spaceID: UUID, at index: Int) {
        guard let s = self.index(of: spaceID) else { return }
        let pair = favoriteSplits.first { $0.contains(id) }
        let ids = pair.map { [$0.left, $0.right] } ?? [id]
        let moving = favorites.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        favorites.removeAll { ids.contains($0.id) }
        favoriteSplits.removeAll { $0.contains(id) }
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

    /// Each favorite split keeps two different favorites, in no other split, its right page just after its left.
    private func tidyFavorites() {
        let ids = Set(favorites.map(\.id))
        var paired: Set<UUID> = []
        favoriteSplits = favoriteSplits.filter { split in
            guard split.left != split.right, ids.contains(split.left), ids.contains(split.right),
                  !paired.contains(split.left), !paired.contains(split.right) else { return false }
            paired.formUnion([split.left, split.right])
            return true
        }
        for split in favoriteSplits {
            guard let from = favorites.firstIndex(where: { $0.id == split.right }) else { continue }
            let right = favorites.remove(at: from)
            favorites.insert(right, at: (favorites.firstIndex { $0.id == split.left } ?? favorites.count - 1) + 1)
        }
    }

    /// Adds the ones not already here; returns how many that was.
    @discardableResult
    func appendFavorites(_ new: [Bookmark]) -> Int {
        let known = Set(favorites.map { $0.url.absoluteString })
        let added = new.filter { !known.contains($0.url.absoluteString) }
        favorites += added
        commit()
        return added.count
    }

    func spaceID(ofBookmark id: UUID) -> UUID? {
        spaces.first { $0.bookmarks.contains { $0.id == id } }?.id
    }

    @discardableResult
    func addBookmark(url: URL, title: String, to spaceID: UUID, at index: Int? = nil, id: UUID = UUID()) -> Bookmark? {
        guard let s = self.index(of: spaceID) else { return nil }
        let bookmark = Bookmark(id: id, url: url, title: title)
        let at = min(index ?? spaces[s].bookmarks.count, spaces[s].bookmarks.count)
        spaces[s].bookmarks.insert(bookmark, at: at)
        // Landing between a folder's pages doesn't put it in the folder: it goes just after, where the sidebar shows it.
        tidyFolders(s)
        commit()
        return bookmark
    }

    /// Many at the end of a space in one change (an import of thousands), saved and shown once.
    func appendBookmarks(_ new: [(url: URL, title: String)], to spaceID: UUID) -> [Bookmark] {
        guard let s = self.index(of: spaceID), !new.isEmpty else { return [] }
        let added = new.map { Bookmark(id: UUID(), url: $0.url, title: $0.title) }
        spaces[s].bookmarks += added
        tidyFolders(s)
        commit()
        return added
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

    /// Moves a pinned page to a place in a space's list. `folder`: the folder it lands in (nil: none); when left
    /// out, it keeps the folder it's in if it stays in the same space. Half of a pinned split moves the pair.
    func moveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?? = .none) {
        guard bookmark(id) != nil, let target = self.index(of: spaceID) else { return }
        let from = self.spaceID(ofBookmark: id)
        let pinned = pinnedSplit(containing: id)
        let ids = pinned.map { [$0.left, $0.right] } ?? [id]
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
        let inside = (spaces[s].folders ?? []).pages(in: id)
        return spaces[s].bookmarks.map(\.id).filter { inside.contains($0) }
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
            if let p = spaces[s].folders?.firstIndex(where: { $0.id == inside }) { spaces[s].folders?[p].isOpen = true }
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

    func setFolderOpen(_ id: UUID, _ open: Bool) {
        guard let s = spaceIndex(ofFolder: id), let f = spaces[s].folders?.firstIndex(where: { $0.id == id }) else { return }
        spaces[s].folders?[f].isOpen = open
        commit()
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
        spaces[target].bookmarks.insert(contentsOf: moving, at: min(at, spaces[target].bookmarks.count))
        folder.parentID = into
        spaces[s].folders?[f] = folder
        if let p = into, let pi = spaces[target].folders?.firstIndex(where: { $0.id == p }) { spaces[target].folders?[pi].isOpen = true }
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
        for split in splits where group[split.left] == nil { group[split.left] = split.left; group[split.right] = split.left }
        let at = max(0, min(index, ids.count))
        guard at > 0, at < ids.count, let g = group[ids[at - 1]], group[ids[at]] == g else { return at }
        var start = at, end = at
        while start > 0, group[ids[start - 1]] == g { start -= 1 }
        while end < ids.count, group[ids[end]] == g { end += 1 }
        return at - start <= end - at ? start : end
    }

    /// Puts a pinned page in a folder of its space (at the end of it), or takes it out of any folder (nil).
    func setFolder(of bookmarkID: UUID, to folderID: UUID?) {
        // A pinned split goes in as one: its left page leads, and its right one follows it there.
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

    /// The rule behind pinned splits, on its own so it can be checked: a split keeps two different pages that are in
    /// the list and in no other split, and its right page sits just after its left one, in the same folder.
    nonisolated static func tidied(_ bookmarks: [Bookmark], _ folders: [BookmarkFolder], _ splits: [PinnedSplit])
        -> (bookmarks: [Bookmark], folders: [BookmarkFolder], splits: [PinnedSplit]) {
        let ids = Set(bookmarks.map(\.id))
        var paired: Set<UUID> = []
        let kept = splits.filter { split in
            guard split.left != split.right, ids.contains(split.left), ids.contains(split.right),
                  !paired.contains(split.left), !paired.contains(split.right) else { return false }
            paired.formUnion([split.left, split.right])
            return true
        }
        var list = bookmarks
        var folders = folders
        for split in kept {
            guard let from = list.firstIndex(where: { $0.id == split.right }) else { continue }
            let right = list.remove(at: from)
            list.insert(right, at: (list.firstIndex { $0.id == split.left } ?? list.count - 1) + 1)
            for f in folders.indices {
                folders[f].bookmarkIDs.removeAll { $0 == split.right }
                if folders[f].bookmarkIDs.contains(split.left) { folders[f].bookmarkIDs.append(split.right) }
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

    /// Pins two pages of a split view together at a place in a space's list, the left one first, in one change.
    func addPinnedSplit(_ left: Bookmark, _ right: Bookmark, to spaceID: UUID, at index: Int? = nil, ratio: Double = 0.5, vertical: Bool = false) {
        guard let s = self.index(of: spaceID) else { return }
        let at = min(index ?? spaces[s].bookmarks.count, spaces[s].bookmarks.count)
        spaces[s].bookmarks.insert(contentsOf: [left, right], at: at)
        var split = PinnedSplit(left: left.id, right: right.id)
        split.ratio = ratio
        split.vertical = vertical
        spaces[s].pinnedSplits = (spaces[s].pinnedSplits ?? []) + [split]
        tidyFolders(s)
        commit()
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

    /// How an open pinned split was last laid out, so it opens that way again. A swap trades its pages' places in the
    /// list too; a new size or direction is only saved.
    func setPinnedSplitLayout(_ layout: PinnedSplit) {
        if let i = favoriteSplits.firstIndex(where: { $0.contains(layout.left) && $0.contains(layout.right) }) {
            let swapped = favoriteSplits[i].left != layout.left
            favoriteSplits[i] = layout
            if swapped { tidyFavorites(); commit() } else { save() }
            return
        }
        for s in spaces.indices {
            guard let i = spaces[s].pinnedSplits?.firstIndex(where: { $0.contains(layout.left) && $0.contains(layout.right) }) else { continue }
            let swapped = spaces[s].pinnedSplits?[i].left != layout.left
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

    /// Replaces everything with imported spaces (used by Arc import, only when the library is untouched).
    func replaceSpaces(_ newSpaces: [SpaceInfo]) {
        guard !newSpaces.isEmpty else { return }
        spaces = newSpaces
        commit()
    }

    /// Spaces, bookmarks and favorites as they are now, for undo.
    struct Snapshot: Equatable {
        fileprivate let spaces: [SpaceInfo]
        fileprivate let favorites: [Bookmark]
        fileprivate let favoriteSplits: [PinnedSplit]
        var spaceIDs: Set<UUID> { Set(spaces.map(\.id)) }
    }

    var snapshot: Snapshot { Snapshot(spaces: spaces, favorites: favorites, favoriteSplits: favoriteSplits) }

    func restore(_ snapshot: Snapshot) {
        spaces = snapshot.spaces
        favorites = snapshot.favorites
        favoriteSplits = snapshot.favoriteSplits
        commit()
    }

    func appendSpaces(_ newSpaces: [SpaceInfo]) {
        spaces.append(contentsOf: newSpaces)
        commit()
    }
}

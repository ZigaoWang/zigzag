import AppKit

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
}

struct SpaceInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: SpaceColor
    var bookmarks: [Bookmark] = []
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
    /// The frame is frosted glass: the desktop shows through, softly tinted. Nil: solid.
    var glass: Bool? = nil
    /// How light or dark the space is, from 0 (lightest) to 1 (darkest); the window's mode follows it.
    /// Nil: automatic, light by day and dark at night with the system.
    var brightness: Double? = nil
    /// The second color's own brightness; nil: the same as the first.
    var brightness2: Double? = nil
    /// What washes over the glass: white to black with the brightness, or with the system when automatic.
    var glassColor: NSColor {
        brightness.map { NSColor(white: 1 - CGFloat($0), alpha: 0.5) }
            ?? Tokens.Color.dynamic(light: NSColor(white: 1, alpha: 0.5), dark: NSColor(white: 0, alpha: 0.5))
    }

    /// The window frame color for this space.
    var background: NSColor {
        if let brightness {
            return SpaceColor.fixed(hue: baseHue, intensity: hue == nil ? SpaceColor.defaultIntensity : intensity ?? SpaceColor.defaultIntensity,
                                    brightness: brightness, neutral: hue == nil && color.isNeutral)
        }
        return hue.map { SpaceColor.background(hue: $0, intensity: intensity ?? SpaceColor.defaultIntensity) } ?? color.background
    }
    /// The strong version, for dots and swatches.
    var swatch: NSColor { hue.map(SpaceColor.swatch(hue:)) ?? color.swatch }
    /// The hue the space is built on, curated or custom.
    var baseHue: Double { hue ?? color.hue }
    /// Where the gradient ends, at the same strength as the first color.
    var background2: NSColor? {
        hue2.map { h in
            let i = intensity2 ?? intensity ?? SpaceColor.defaultIntensity
            return (brightness2 ?? brightness).map { SpaceColor.fixed(hue: h, intensity: i, brightness: $0, neutral: false) } ?? SpaceColor.background(hue: h, intensity: i)
        }
    }
    var gradientAngle: Double { angle ?? 45 }
}

enum SearchEngine: String, Codable, CaseIterable {
    case google, duckDuckGo, brave, bing, kagi, ecosia

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave Search"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        }
    }

    func searchURL(_ query: String) -> URL {
        var components: URLComponents
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")!
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
        case .brave: components = URLComponents(string: "https://search.brave.com/search")!
        case .bing: components = URLComponents(string: "https://www.bing.com/search")!
        case .kagi: components = URLComponents(string: "https://kagi.com/search")!
        case .ecosia: components = URLComponents(string: "https://www.ecosia.org/search")!
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
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
        var searchEngine: SearchEngine
        var importedFromArc: Bool?
    }

    private(set) var spaces: [SpaceInfo]
    /// Favorites: tiles at the top of the sidebar, the same in every space.
    private(set) var favorites: [Bookmark] = []
    var searchEngine: SearchEngine { didSet { save() } }
    var importedFromArc: Bool { didSet { save() } }

    /// Fires whenever spaces or bookmarks change.
    let changed = Signal<Void>()

    private init() {
        if let stored = JSONStore.load(Stored.self, from: Paths.library), !stored.spaces.isEmpty {
            spaces = stored.spaces
            favorites = stored.favorites ?? []
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
        JSONStore.save(Stored(spaces: spaces, favorites: favorites, searchEngine: searchEngine, importedFromArc: importedFromArc), to: Paths.library)
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

    func setColor(_ color: SpaceColor, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].color = color
        spaces[i].hue = nil
        spaces[i].intensity = nil
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

    func setGlass(_ on: Bool, for id: UUID) {
        guard let i = index(of: id) else { return }
        spaces[i].glass = on ? true : nil
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

    @discardableResult
    func addFavorite(url: URL, title: String, at index: Int? = nil, id: UUID = UUID()) -> Bookmark {
        let favorite = Bookmark(id: id, url: url, title: title)
        favorites.insert(favorite, at: min(index ?? favorites.count, favorites.count))
        commit()
        return favorite
    }

    func moveFavorite(_ id: UUID, to index: Int) {
        guard let from = favorites.firstIndex(where: { $0.id == id }) else { return }
        let favorite = favorites.remove(at: from)
        favorites.insert(favorite, at: max(0, min(index, favorites.count)))
        commit()
    }

    /// Turns a space bookmark into a favorite, keeping its id (and so its live page).
    func makeFavorite(_ bookmarkID: UUID) {
        guard let bookmark = bookmark(bookmarkID), !isFavorite(bookmarkID) else { return }
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == bookmarkID } }
        favorites.append(bookmark)
        commit()
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
        commit()
        return bookmark
    }

    func removeBookmark(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == id } }
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

    func moveBookmark(_ id: UUID, to index: Int, in spaceID: UUID) {
        guard let bookmark = bookmark(id), let target = self.index(of: spaceID) else { return }
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == id } }
        let at = max(0, min(index, spaces[target].bookmarks.count))
        spaces[target].bookmarks.insert(bookmark, at: at)
        commit()
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

        func favoriteIndex(of id: UUID) -> Int? { favorites.firstIndex { $0.id == id } }
    }

    var snapshot: Snapshot { Snapshot(spaces: spaces, favorites: favorites) }

    func restore(_ snapshot: Snapshot) {
        spaces = snapshot.spaces
        favorites = snapshot.favorites
        commit()
    }

    func appendSpaces(_ newSpaces: [SpaceInfo]) {
        spaces.append(contentsOf: newSpaces)
        commit()
    }
}

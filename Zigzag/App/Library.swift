import AppKit

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
}

/// A named group of a space's pinned pages, folded open or shut in the sidebar. Its pages stay in the space's own list
/// (kept next to each other); the folder only says which ones it holds.
struct BookmarkFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bookmarkIDs: [UUID] = []
    var isOpen = true
}

struct SpaceInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: SpaceColor
    var bookmarks: [Bookmark] = []
    /// Folders of pinned pages. Nil: none yet (older libraries).
    var folders: [BookmarkFolder]? = nil
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

    /// No hue of its own: white, a gray, or black.
    var isNeutral: Bool { hue == nil && color.isNeutral }

    /// The window frame color for this space.
    var background: NSColor {
        if let brightness { return SpaceColor.paint(hue: baseHue, depth: brightness, neutral: isNeutral) }
        return hue.map { SpaceColor.background(hue: $0, intensity: intensity ?? SpaceColor.defaultIntensity) } ?? color.background
    }
    /// The strong version, for dots and swatches.
    var swatch: NSColor {
        if let brightness {
            return isNeutral ? NSColor(white: 0.86 - 0.56 * brightness, alpha: 1)
                : SpaceColor.paint(hue: baseHue, depth: 0.35 + 0.45 * brightness)
        }
        return hue.map(SpaceColor.swatch(hue:)) ?? color.swatch
    }
    /// The hue the space is built on, curated or custom.
    var baseHue: Double { hue ?? color.hue }
    /// Where the gradient ends.
    var background2: NSColor? {
        hue2.map { h in
            if let depth = brightness2 ?? brightness { return SpaceColor.paint(hue: h, depth: depth) }
            return SpaceColor.background(hue: h, intensity: intensity2 ?? intensity ?? SpaceColor.defaultIntensity)
        }
    }
    var gradientAngle: Double { angle ?? 45 }

    /// Light or dark for the window: whichever text reads better on this space's own colors, judged at the
    /// harder end of a gradient. Glass and spaces that follow the Mac keep what they were given.
    var readableAppearance: String? {
        guard brightness != nil, glass != true else { return appearance }
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
        spaces[i].glass = look.glass
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
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == bookmarkID }; tidyFolders(s) }
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
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == id }; tidyFolders(s) }
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
    /// out, it keeps the folder it's in if it stays in the same space.
    func moveBookmark(_ id: UUID, to index: Int, in spaceID: UUID, folder: UUID?? = .none) {
        guard let bookmark = bookmark(id), let target = self.index(of: spaceID) else { return }
        let from = self.spaceID(ofBookmark: id)
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == id } }
        let at = max(0, min(index, spaces[target].bookmarks.count))
        spaces[target].bookmarks.insert(bookmark, at: at)
        let keep: UUID? = from == spaceID ? folderID(containing: id) : nil
        let landsIn: UUID? = switch folder { case .some(let chosen): chosen; case .none: keep }
        for s in spaces.indices {
            for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { $0 == id } }
        }
        if let landsIn, let f = spaces[target].folders?.firstIndex(where: { $0.id == landsIn }) {
            // In the folder at the place it was dropped, by the list's order.
            spaces[target].folders?[f].bookmarkIDs.append(id)
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

    /// A new folder in a space, holding these pinned pages (gathered where the first of them is).
    @discardableResult
    func addFolder(named name: String, with bookmarkIDs: [UUID], in spaceID: UUID) -> BookmarkFolder? {
        guard let s = self.index(of: spaceID) else { return nil }
        let members = spaces[s].bookmarks.map(\.id).filter { bookmarkIDs.contains($0) }
        for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { members.contains($0) } }
        let folder = BookmarkFolder(name: name, bookmarkIDs: members)
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

    func setFolderOpen(_ id: UUID, _ open: Bool) {
        guard let s = spaceIndex(ofFolder: id), let f = spaces[s].folders?.firstIndex(where: { $0.id == id }) else { return }
        spaces[s].folders?[f].isOpen = open
        commit()
    }

    /// The folder goes; the pinned pages in it stay where they are.
    func removeFolder(_ id: UUID) {
        guard let s = spaceIndex(ofFolder: id) else { return }
        spaces[s].folders?.removeAll { $0.id == id }
        commit()
    }

    /// Puts a pinned page in a folder of its space (at the end of it), or takes it out of any folder (nil).
    func setFolder(of bookmarkID: UUID, to folderID: UUID?) {
        guard let s = spaces.firstIndex(where: { $0.bookmarks.contains { $0.id == bookmarkID } }) else { return }
        for f in (spaces[s].folders ?? []).indices { spaces[s].folders?[f].bookmarkIDs.removeAll { $0 == bookmarkID } }
        if let folderID, let f = spaces[s].folders?.firstIndex(where: { $0.id == folderID }) {
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

    /// Keeps folders honest: only pages still in the space, and each folder's pages side by side in the list, where
    /// its first page is (or, for `keeping`, around the page just moved, so a drop lands where it was dropped).
    private func tidyFolders(_ s: Int, keepingPlaceOf moved: UUID? = nil) {
        guard let folders = spaces[s].folders, !folders.isEmpty else { return }
        (spaces[s].bookmarks, spaces[s].folders) = Self.tidied(spaces[s].bookmarks, folders)
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
        var result: [Bookmark] = []
        var placed: Set<UUID> = []
        let byID = Dictionary(bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for bookmark in bookmarks where !placed.contains(bookmark.id) {
            if let folder = folders.first(where: { $0.bookmarkIDs.contains(bookmark.id) }) {
                for id in folder.bookmarkIDs where !placed.contains(id) {
                    if let b = byID[id] { result.append(b); placed.insert(id) }
                }
            } else {
                result.append(bookmark)
                placed.insert(bookmark.id)
            }
        }
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

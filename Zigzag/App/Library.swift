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
}

enum SearchEngine: String, Codable, CaseIterable {
    case google, duckDuckGo, bing, kagi, ecosia

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
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
        case .bing: components = URLComponents(string: "https://www.bing.com/search")!
        case .kagi: components = URLComponents(string: "https://kagi.com/search")!
        case .ecosia: components = URLComponents(string: "https://www.ecosia.org/search")!
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
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
        var searchEngine: SearchEngine
        var importedFromArc: Bool?
    }

    private(set) var spaces: [SpaceInfo]
    var searchEngine: SearchEngine { didSet { save() } }
    var importedFromArc: Bool { didSet { save() } }

    /// Fires whenever spaces or bookmarks change.
    let changed = Signal<Void>()

    private init() {
        if let stored = JSONStore.load(Stored.self, from: Paths.library), !stored.spaces.isEmpty {
            spaces = stored.spaces
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
        JSONStore.save(Stored(spaces: spaces, searchEngine: searchEngine, importedFromArc: importedFromArc), to: Paths.library)
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
        let pick = color ?? SpaceColor.allCases.first { $0 != .graphite && !used.contains($0) } ?? SpaceColor.allCases[spaces.count % SpaceColor.allCases.count]
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
        commit()
    }

    func removeSpace(_ id: UUID) {
        guard spaces.count > 1, let i = index(of: id) else { return }
        spaces.remove(at: i)
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

    var allBookmarks: [(Bookmark, SpaceInfo)] {
        spaces.flatMap { space in space.bookmarks.map { ($0, space) } }
    }

    func bookmark(_ id: UUID) -> Bookmark? {
        for space in spaces { if let b = space.bookmarks.first(where: { $0.id == id }) { return b } }
        return nil
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
        for s in spaces.indices { spaces[s].bookmarks.removeAll { $0.id == id } }
        commit()
    }

    func updateBookmark(_ id: UUID, title: String? = nil, url: URL? = nil) {
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

    func appendSpaces(_ newSpaces: [SpaceInfo]) {
        spaces.append(contentsOf: newSpaces)
        commit()
    }
}

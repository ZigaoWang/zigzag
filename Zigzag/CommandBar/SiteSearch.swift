import AppKit

/// Searching one site straight from the address bar: type the start of its name ("you", "git"), press Tab, and
/// what you type next searches that site.
struct SiteSearch: Equatable {
    /// A built-in's first key ("youtube"), or `custom:` and the ID of a site you added.
    let id: String
    let name: String
    /// What you might type to mean it: its name, its address, short forms.
    let keys: [String]
    /// The search address, with `%s` where the query goes.
    let template: String
    let home: URL
    /// The chip's color, from the site's own.
    let color: NSColor

    init(id: String? = nil, name: String, keys: [String], template: String, home: URL, color: NSColor) {
        self.id = id ?? keys[0]
        self.name = name
        self.keys = keys
        self.template = template
        self.home = home
        self.color = color
    }

    static func == (a: SiteSearch, b: SiteSearch) -> Bool { a.id == b.id }

    var isCustom: Bool { id.hasPrefix(CustomSiteSearch.idPrefix) }

    func url(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// The keyword Settings shows: the shortest of its keys that isn't an address or two words.
    var keyword: String { keys.filter { !$0.contains(".") && !$0.contains(" ") }.min { $0.count < $1.count } ?? keys[0] }

    private static func hex(_ v: UInt32) -> NSColor { Tokens.Color.hex(v) }

    /// The sites Tab searches: the built-ins left on, then the ones you added (`SiteSearches`).
    static var all: [SiteSearch] { builtIn.filter { SiteSearches.isOn($0.id) } + SiteSearches.custom.filter(\.isEnabled).map(\.site) }

    /// Zigzag's own, most used first: when two match what you've typed, the earlier one wins.
    static let builtIn: [SiteSearch] = [
        SiteSearch(name: "YouTube", keys: ["youtube", "youtube.com", "yt"], template: "https://www.youtube.com/results?search_query=%s", home: URL(string: "https://www.youtube.com")!, color: hex(0xFF0033)),
        SiteSearch(name: "GitHub", keys: ["github", "github.com", "gh"], template: "https://github.com/search?q=%s&type=repositories", home: URL(string: "https://github.com")!, color: hex(0x24292F)),
        SiteSearch(name: "AvoidXray", keys: ["avoidxray", "avoidxray.com", "axr"], template: "https://avoidxray.com/search?q=%s", home: URL(string: "https://avoidxray.com")!, color: hex(0xD8352B)),
        SiteSearch(name: "Google", keys: ["google", "google.com"], template: "https://www.google.com/search?q=%s", home: URL(string: "https://www.google.com")!, color: hex(0x4285F4)),
        SiteSearch(name: "Wikipedia", keys: ["wikipedia", "wikipedia.org", "wiki"], template: "https://en.wikipedia.org/w/index.php?search=%s", home: URL(string: "https://en.wikipedia.org")!, color: hex(0x3A3A3A)),
        SiteSearch(name: "Claude", keys: ["claude", "claude.ai"], template: "https://claude.ai/new?q=%s", home: URL(string: "https://claude.ai")!, color: hex(0xD97757)),
        SiteSearch(name: "ChatGPT", keys: ["chatgpt", "chatgpt.com", "gpt"], template: "https://chatgpt.com/?q=%s", home: URL(string: "https://chatgpt.com")!, color: hex(0x10A37F)),
        SiteSearch(name: "Perplexity", keys: ["perplexity", "perplexity.ai"], template: "https://www.perplexity.ai/search?q=%s", home: URL(string: "https://www.perplexity.ai")!, color: hex(0x1F8A8A)),
        SiteSearch(name: "Reddit", keys: ["reddit", "reddit.com"], template: "https://www.reddit.com/search/?q=%s", home: URL(string: "https://www.reddit.com")!, color: hex(0xFF4500)),
        SiteSearch(name: "X", keys: ["x.com", "twitter", "twitter.com"], template: "https://x.com/search?q=%s", home: URL(string: "https://x.com")!, color: hex(0x111111)),
        SiteSearch(name: "Google Maps", keys: ["maps", "google maps", "maps.google.com"], template: "https://www.google.com/maps/search/%s", home: URL(string: "https://www.google.com/maps")!, color: hex(0x34A853)),
        SiteSearch(name: "Google Images", keys: ["images", "google images"], template: "https://www.google.com/search?tbm=isch&q=%s", home: URL(string: "https://images.google.com")!, color: hex(0x4285F4)),
        SiteSearch(name: "Amazon", keys: ["amazon", "amazon.com"], template: "https://www.amazon.com/s?k=%s", home: URL(string: "https://www.amazon.com")!, color: hex(0xFF9900)),
        SiteSearch(name: "Stack Overflow", keys: ["stackoverflow", "stack overflow", "stackoverflow.com", "so"], template: "https://stackoverflow.com/search?q=%s", home: URL(string: "https://stackoverflow.com")!, color: hex(0xF48024)),
        SiteSearch(name: "MDN", keys: ["mdn", "developer.mozilla.org"], template: "https://developer.mozilla.org/en-US/search?q=%s", home: URL(string: "https://developer.mozilla.org")!, color: hex(0x1B1B1B)),
        SiteSearch(name: "npm", keys: ["npm", "npmjs.com"], template: "https://www.npmjs.com/search?q=%s", home: URL(string: "https://www.npmjs.com")!, color: hex(0xCB3837)),
        SiteSearch(name: "Apple Developer", keys: ["apple developer", "developer.apple.com"], template: "https://developer.apple.com/search/?q=%s", home: URL(string: "https://developer.apple.com")!, color: hex(0x1D1D1F)),
        SiteSearch(name: "Spotify", keys: ["spotify", "open.spotify.com"], template: "https://open.spotify.com/search/%s", home: URL(string: "https://open.spotify.com")!, color: hex(0x1DB954)),
        SiteSearch(name: "Bilibili", keys: ["bilibili", "bilibili.com", "bili"], template: "https://search.bilibili.com/all?keyword=%s", home: URL(string: "https://www.bilibili.com")!, color: hex(0x00A1D6)),
        SiteSearch(name: "IMDb", keys: ["imdb", "imdb.com"], template: "https://www.imdb.com/find/?q=%s", home: URL(string: "https://www.imdb.com")!, color: hex(0xF5C518)),
        SiteSearch(name: "DuckDuckGo", keys: ["duckduckgo", "ddg", "duckduckgo.com"], template: "https://duckduckgo.com/?q=%s", home: URL(string: "https://duckduckgo.com")!, color: hex(0xDE5833)),
    ]

    /// The site what you've typed points at: at least two letters into one of its names, and only a name, not a
    /// sentence. "you" and "youtube.com" both mean YouTube; "youtube cats" means a search. The keyword of a site you
    /// added, typed whole, comes first.
    static func match(_ typed: String, among all: [SiteSearch] = all) -> SiteSearch? {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.count >= 2 else { return nil }
        let bare = text.withoutWWW
        // Exact short forms first ("gh", "yt"), then the start of a name.
        if let exact = all.first(where: { $0.isCustom && $0.keys.first == bare }) ?? all.first(where: { $0.keys.contains(bare) }) { return exact }
        guard bare.count >= 3, !bare.contains(" ") || all.contains(where: { $0.keys.contains { $0.hasPrefix(bare) && $0.contains(" ") } }) else { return nil }
        return all.first { site in site.keys.contains { $0.hasPrefix(bare) } }
    }
}

/// A site you added in Settings › Search › Site Search: its name, the keyword that starts it and its search address.
struct CustomSiteSearch: Codable, Equatable, Identifiable {
    static let idPrefix = "custom:"

    var id: UUID
    var name: String
    var keyword: String
    /// With `%s` where the words go.
    var template: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, keyword: String, template: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.template = template
        self.isEnabled = isEnabled
    }

    /// A field missing, as from another version, never loses the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? ""
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// The scheme and host of its search address.
    var home: URL? {
        guard let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")), let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    /// As the command bar uses it: known by its keyword, then its name and its address.
    var site: SiteSearch {
        let home = home ?? URL(string: "https://example.com")!
        var keys: [String] = []
        for key in [keyword.lowercased(), name.lowercased(), (home.host() ?? "").lowercased().withoutWWW] where !key.isEmpty && !keys.contains(key) {
            keys.append(key)
        }
        return SiteSearch(id: Self.idPrefix + id.uuidString, name: name, keys: keys.isEmpty ? [id.uuidString] : keys, template: template, home: home,
                          color: Tokens.Color.textPrimary)
    }
}

/// What Settings › Search › Site Search keeps: the built-ins turned off and the sites you added. One preference,
/// synced and backed up with the other search settings.
enum SiteSearches {
    /// Tests use their own.
    static var defaults: UserDefaults = .standard
    static let key = "SiteSearches"
    /// Changed here, in another window's Settings or by sync.
    static let changed = Signal<Void>()

    struct Saved: Codable, Equatable {
        /// Built-ins turned off, by ID.
        var off: [String] = []
        var custom: [CustomSiteSearch] = []

        init(off: [String] = [], custom: [CustomSiteSearch] = []) {
            self.off = off
            self.custom = custom
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            off = try c.decodeIfPresent([String].self, forKey: .off) ?? []
            custom = try c.decodeIfPresent([CustomSiteSearch].self, forKey: .custom) ?? []
        }
    }

    static var saved: Saved {
        get {
            guard let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
            return saved
        }
        set {
            if newValue == Saved() { defaults.removeObject(forKey: key) } else if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: key) }
            changed.send()
        }
    }

    static var custom: [CustomSiteSearch] { saved.custom }

    static func isOn(_ builtInID: String) -> Bool { !saved.off.contains(builtInID) }

    static func setOn(_ on: Bool, builtIn id: String) {
        var saved = saved
        saved.off.removeAll { $0 == id }
        if !on { saved.off.append(id) }
        self.saved = saved
    }

    static func setEnabled(_ on: Bool, custom id: UUID) {
        var saved = saved
        guard let index = saved.custom.firstIndex(where: { $0.id == id }) else { return }
        saved.custom[index].isEnabled = on
        self.saved = saved
    }

    /// Adds `site`, or puts it in place of the one with its ID, as it's kept; nil when it can't be saved as typed.
    @discardableResult
    static func save(_ site: CustomSiteSearch) -> CustomSiteSearch? {
        guard problem(name: site.name, keyword: site.keyword, template: site.template, editing: site.id) == nil,
              let template = template(site.template) else { return nil }
        var kept = site
        kept.name = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
        kept.keyword = site.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        kept.template = template
        var saved = saved
        if let index = saved.custom.firstIndex(where: { $0.id == site.id }) { saved.custom[index] = kept } else { saved.custom.append(kept) }
        self.saved = saved
        return kept
    }

    static func remove(_ id: UUID) {
        var saved = saved
        saved.custom.removeAll { $0.id == id }
        self.saved = saved
    }

    enum Problem: Equatable {
        case noName, keywordTooShort, spaceInKeyword, invalidTemplate
        /// Another site's keyword: that site's name.
        case keywordTaken(String)
    }

    /// Why a site can't be saved as typed, or nil. A keyword is one word of two letters or more, used by no other
    /// site you added and no built-in that's on, whatever its case. The address is http or https with a host, and
    /// one `%s` or `{query}` where the words go.
    static func problem(name: String, keyword: String, template: String, editing id: UUID? = nil) -> Problem? {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noName }
        if keyword.contains(where: \.isWhitespace) { return .spaceInKeyword }
        if keyword.count < 2 { return .keywordTooShort }
        if let other = custom.first(where: { $0.id != id && $0.keyword.lowercased() == keyword }) { return .keywordTaken(other.name) }
        if let other = SiteSearch.builtIn.first(where: { isOn($0.id) && $0.keys.contains(keyword) }) { return .keywordTaken(other.name) }
        if self.template(template) == nil { return .invalidTemplate }
        return nil
    }

    /// The search address as it's kept, `{query}` written as `%s` and https:// added when left out; nil when it
    /// can't search.
    static func template(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "{query}", with: "%s")
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        guard text.components(separatedBy: "%s").count == 2, SearchEngine.isValidTemplate(text) else { return nil }
        return text
    }
}

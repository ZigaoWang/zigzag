import AppKit

/// Searching one site straight from the address bar: type the start of its name ("you", "git"), press Tab, and
/// what you type next searches that site.
struct SiteSearch: Equatable {
    let name: String
    /// What you might type to mean it: its name, its address, short forms.
    let keys: [String]
    /// The search address, with `%s` where the query goes.
    let template: String
    let home: URL
    /// The chip's color, from the site's own.
    let color: NSColor

    static func == (a: SiteSearch, b: SiteSearch) -> Bool { a.name == b.name }

    func url(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    private static func hex(_ v: UInt32) -> NSColor { Tokens.Color.hex(v) }

    /// Most used first: when two match what you've typed, the earlier one wins.
    static let all: [SiteSearch] = [
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
    /// sentence. "you" and "youtube.com" both mean YouTube; "youtube cats" means a search.
    static func match(_ typed: String) -> SiteSearch? {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.count >= 2 else { return nil }
        let bare = text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
        // Exact short forms first ("gh", "yt"), then the start of a name.
        if let exact = all.first(where: { $0.keys.contains(bare) }) { return exact }
        guard bare.count >= 3, !bare.contains(" ") || all.contains(where: { $0.keys.contains { $0.hasPrefix(bare) && $0.contains(" ") } }) else { return nil }
        return all.first { site in site.keys.contains { $0.hasPrefix(bare) } }
    }
}

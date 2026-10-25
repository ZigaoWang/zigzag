import AppKit

/// One line in the command bar.
struct CommandResult: Equatable {
    enum Kind: Equatable {
        case open(URL)
        case search(String)
        /// A search on one site, from the address bar's site search.
        case searchOn(URL)
        case switchTo(UUID)
        case bookmark(UUID)
        case history(URL)
        case suggestion(String)
        /// A Zigzag command ("Import from Another Browser…"), by its ID in `CommandRanker.actions`.
        case action(String)
    }

    let kind: Kind
    let title: String
    let detail: String
    var icon: NSImage?
    var symbol: String?

    var actionLabel: String {
        switch kind {
        case .open, .history: "Open"
        case .search, .suggestion, .searchOn: "Search"
        case .switchTo: "Switch to Tab"
        case .bookmark: "Open Bookmark"
        case .action: "Run"
        }
    }

    static func == (a: CommandResult, b: CommandResult) -> Bool { a.kind == b.kind && a.title == b.title && a.detail == b.detail }
}

/// Turns what you typed into ranked results: URLs, searches, open tabs, bookmarks and history.
enum CommandRanker {
    /// A URL if the text looks like an address, otherwise nil.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") || lower.hasPrefix("about:") {
            return URL(string: trimmed)
        }
        // An email address is something to search for, not a place to go.
        if lower.contains("@") { return nil }
        // The host is everything before the first of / ? #; the port comes off too.
        let hostEnd = lower.firstIndex { "/?#".contains($0) } ?? lower.endIndex
        let hostPart = String(lower[..<hostEnd])
        let host = hostPart.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? hostPart
        if host == "localhost" || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + trimmed)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last.map(String.init) else { return nil }
        // Names only a local network knows go over plain http, the way a printer or router serves them.
        if localTLDs.contains(tld) { return URL(string: "http://" + trimmed) }
        // A real top-level domain, so "node.js" and "readme.txt" are searched, not opened.
        guard knownTLDs.contains(tld) || tld.hasPrefix("xn--") else { return nil }
        return URL(string: "https://" + trimmed)
    }

    private static let localTLDs: Set<String> = ["local", "lan", "internal", "test", "localhost", "home", "arpa", "corp", "intranet"]

    /// Every top-level domain IANA lists, bundled with the app.
    private static let knownTLDs: Set<String> = {
        guard let url = Bundle.main.url(forResource: "tlds", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ["com", "org", "net", "io", "app", "dev"] }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }()

    static func matches(_ words: [String], _ haystacks: String...) -> Bool {
        let joined = haystacks.joined(separator: " ").lowercased()
        return words.allSatisfy { joined.contains($0) }
    }

    static func displayURL(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The bare host completion for inline autocomplete, e.g. "git" → "github.com".
    static func inlineCompletion(for text: String, manager: TabManager) -> (completion: String, url: URL)? {
        let lower = text.lowercased()
        guard lower.count >= 1, !lower.contains(" "), !lower.contains("/") else { return nil }
        func host(_ url: URL) -> String { HistoryStore.normalizedHost(url) }
        // The site's own scheme and port come along: "loc" completes to localhost:3000 over http, as it was.
        func root(_ url: URL) -> (String, URL)? {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            let h = host(url)
            let shown = url.port.map { "\(h):\($0)" } ?? h
            return URL(string: "\(scheme)://\(shown)").map { (shown, $0) }
        }
        let candidates: [URL] = manager.allTabs.compactMap(\.url) + Library.shared.favorites.map(\.url) + Library.shared.allBookmarks.map(\.0.url)
        for url in candidates where host(url).hasPrefix(lower) {
            if let found = root(url) { return (found.0, found.1) }
        }
        if let entry = HistoryStore.shared.bestHostCompletion(for: lower), let found = root(entry.url) {
            return (found.0, found.1)
        }
        return nil
    }

    struct Action {
        let id: String
        let title: String
        let keywords: [String]
        let symbol: String
    }

    static let actions: [Action] = [
        Action(id: "clear-cache", title: "Clear Cache", keywords: ["clear", "cache", "empty", "reset", "refresh"], symbol: "arrow.clockwise"),
        Action(id: "clear-cookies", title: "Clear Cookies…", keywords: ["clear", "cookies", "sign", "out", "logout", "reset", "data"], symbol: "trash"),
        Action(id: "passwords", title: "Passwords", keywords: ["passwords", "logins", "keychain", "accounts"], symbol: "key.fill"),
        Action(id: "import", title: "Import from Another Browser…", keywords: ["import", "bring", "move", "switch", "passwords", "bookmarks", "arc", "chrome", "safari", "firefox"], symbol: "square.and.arrow.down"),
        Action(id: "feedback", title: "Send Feedback…", keywords: ["feedback", "send", "report", "bug", "issue", "problem", "suggest", "idea", "contact", "email", "help"], symbol: "bubble.left"),
    ]

    static func results(for text: String, manager: TabManager, suggestions: [String], editingCurrent: Bool, historyOnly: Bool) -> [CommandResult] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [CommandResult] = []
        var seen = Set<String>()
        func add(_ result: CommandResult, key: String) {
            guard !seen.contains(key) else { return }
            seen.insert(key)
            results.append(result)
        }

        if query.isEmpty {
            if historyOnly {
                for entry in HistoryStore.shared.recent(limit: 8) {
                    add(CommandResult(kind: .history(entry.url), title: entry.title.isEmpty ? displayURL(entry.url) : entry.title,
                                      detail: displayURL(entry.url), icon: FaviconStore.shared.cachedIcon(for: entry.url)),
                        key: TabManager.normalize(entry.url))
                }
                return results
            }
            // Nothing typed yet: recent tabs, so switching is one keystroke away.
            for tab in manager.recentTabs.prefix(6) where tab !== manager.selectedTab {
                guard let url = tab.url else { continue }
                add(CommandResult(kind: .switchTo(tab.id), title: tab.displayTitle, detail: displayURL(url), icon: tab.favicon),
                    key: TabManager.normalize(url))
            }
            return results
        }

        let words = query.lowercased().split(separator: " ").map(String.init)
        let engine = Library.shared.searchEngine

        // Zigzag's own commands, when the words fit one. They come first: typing "import" means the command.
        if !historyOnly {
            for action in actions where words.allSatisfy({ word in action.keywords.contains { $0.hasPrefix(word) } }) {
                add(CommandResult(kind: .action(action.id), title: action.title, detail: "", symbol: action.symbol), key: "action:\(action.id)")
            }
        }

        if !historyOnly {
            if let url = url(from: query) {
                add(CommandResult(kind: .open(url), title: displayURL(url), detail: "", icon: FaviconStore.shared.cachedIcon(for: url), symbol: "globe"),
                    key: TabManager.normalize(url))
            } else {
                add(CommandResult(kind: .search(query), title: query, detail: engine.name, symbol: "magnifyingglass"), key: "search:\(query)")
            }
        }

        if !historyOnly {
            var tabCount = 0
            for tab in manager.recentTabs + manager.allTabs where tabCount < 3 {
                guard let url = tab.url, matches(words, tab.displayTitle, url.absoluteString) else { continue }
                let key = TabManager.normalize(url)
                guard !seen.contains(key) else { continue }
                add(CommandResult(kind: .switchTo(tab.id), title: tab.displayTitle, detail: displayURL(url), icon: tab.favicon), key: key)
                tabCount += 1
            }
            var bookmarkCount = 0
            // Favorites first: they're the sites you go to most.
            for bookmark in Library.shared.favorites + Library.shared.allBookmarks.map(\.0) where bookmarkCount < 3 {
                guard matches(words, bookmark.title, bookmark.url.absoluteString) else { continue }
                let key = TabManager.normalize(bookmark.url)
                guard !seen.contains(key) else { continue }
                add(CommandResult(kind: .bookmark(bookmark.id), title: bookmark.title, detail: displayURL(bookmark.url),
                                  icon: FaviconStore.shared.cachedIcon(for: bookmark.url)), key: key)
                bookmarkCount += 1
            }
        }

        // Tabs that tidied themselves away: still a few letters from coming back.
        if !historyOnly {
            for entry in TabArchive.shared.search(words, limit: 2) {
                let key = TabManager.normalize(entry.url)
                guard !seen.contains(key) else { continue }
                let space = Library.shared.space(entry.spaceID)?.name
                add(CommandResult(kind: .history(entry.url), title: entry.title.isEmpty ? displayURL(entry.url) : entry.title,
                                  detail: ["Archived", space].compactMap { $0 }.joined(separator: " · "),
                                  icon: FaviconStore.shared.cachedIcon(for: entry.url), symbol: "archivebox"), key: key)
            }
        }

        var historyCount = 0
        let historyLimit = historyOnly ? 10 : 4
        for entry in HistoryStore.shared.search(query, limit: historyLimit * 2) where historyCount < historyLimit {
            let key = TabManager.normalize(entry.url)
            guard !seen.contains(key), !SearchFolding.isSearchResultsPage(entry.url) else { continue }
            add(CommandResult(kind: .history(entry.url), title: entry.title.isEmpty ? displayURL(entry.url) : entry.title,
                              detail: displayURL(entry.url), icon: FaviconStore.shared.cachedIcon(for: entry.url)), key: key)
            historyCount += 1
        }

        if !historyOnly && url(from: query) == nil {
            for suggestion in suggestions.prefix(4) where suggestion.lowercased() != query.lowercased() {
                add(CommandResult(kind: .suggestion(suggestion), title: suggestion, detail: "", symbol: "magnifyingglass"), key: "search:\(suggestion)")
            }
        }
        return Array(results.prefix(Tokens.Metric.commandBarMaxRows))
    }
}

/// Fetches search suggestions from the chosen engine. Only what you type in the command bar is sent.
final class SuggestionFetcher {
    private var task: Task<Void, Never>?

    func fetch(_ query: String, completion: @escaping ([String]) -> Void) {
        task?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, CommandRanker.url(from: trimmed) == nil,
              let url = Library.shared.searchEngine.suggestionsURL(trimmed) else { completion([]); return }
        task = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            completion(Self.parse(data))
        }
    }

    func cancel() { task?.cancel() }

    nonisolated static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // OpenSearch format: [query, [suggestions...]]
        if let array = json as? [Any], array.count > 1, let list = array[1] as? [String] { return list }
        // DuckDuckGo: [{phrase: ...}]
        if let array = json as? [[String: Any]] { return array.compactMap { $0["phrase"] as? String } }
        // Kagi: [{t: ...}] or {data: [...]}
        if let dict = json as? [String: Any], let list = dict["suggestions"] as? [[String: Any]] {
            return list.compactMap { ($0["value"] ?? $0["t"]) as? String }
        }
        return []
    }
}

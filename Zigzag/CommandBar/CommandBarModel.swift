import AppKit

/// One line in the command bar.
struct CommandResult: Equatable {
    enum Kind: Equatable {
        case open(URL)
        case search(String)
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
        case .search, .suggestion: "Search"
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
        if lower.hasPrefix("localhost") || lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + trimmed)
        }
        // Something like "name.tld" or "name.tld/path": a dot, a plausible TLD, no spaces.
        let hostPart = lower.split(separator: "/").first.map(String.init) ?? lower
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter }),
              labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return URL(string: "https://" + trimmed)
    }

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
        let candidates: [URL] = manager.allTabs.compactMap(\.url) + Library.shared.allBookmarks.map(\.0.url)
        if let url = candidates.first(where: { host($0).hasPrefix(lower) }) {
            return (host(url), URL(string: "https://\(host(url))")!)
        }
        if let entry = HistoryStore.shared.bestHostCompletion(for: lower) {
            let h = host(entry.url)
            return (h, URL(string: "\(entry.url.scheme ?? "https")://\(h)")!)
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
        Action(id: "passwords", title: "Passwords", keywords: ["passwords", "logins", "keychain", "accounts"], symbol: "key.fill"),
        Action(id: "import", title: "Import from Another Browser…", keywords: ["import", "bring", "move", "switch", "passwords", "bookmarks", "arc", "chrome", "safari", "firefox"], symbol: "square.and.arrow.down"),
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
            for (bookmark, _) in Library.shared.allBookmarks where bookmarkCount < 3 {
                guard matches(words, bookmark.title, bookmark.url.absoluteString) else { continue }
                let key = TabManager.normalize(bookmark.url)
                guard !seen.contains(key) else { continue }
                add(CommandResult(kind: .bookmark(bookmark.id), title: bookmark.title, detail: displayURL(bookmark.url),
                                  icon: FaviconStore.shared.cachedIcon(for: bookmark.url)), key: key)
                bookmarkCount += 1
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

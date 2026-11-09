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
        /// A line that only says something ("No history yet"): nothing to run, so Return and clicks pass it by.
        case note
    }

    let kind: Kind
    let title: String
    let detail: String
    var icon: NSImage?
    var symbol: String?
    /// A bookmark that's a favorite rather than a pinned tab, so the bar says which it opens.
    var isFavorite = false

    var actionLabel: String {
        switch kind {
        case .open, .history: String(localized: "Open", comment: "Action label at the right of the selected command bar result, saying what Return does: opens the page.")
        case .search, .suggestion, .searchOn: String(localized: "Search", comment: "Action label at the right of the selected command bar result, saying what Return does: searches for it.")
        case .switchTo: String(localized: "Switch to Tab", comment: "Action label at the right of the selected command bar result, saying what Return does: goes to the open tab.")
        case .bookmark: isFavorite ? String(localized: "Open Favorite", comment: "Action label at the right of the selected command bar result, saying what Return does: opens the favorite.")
                                    : String(localized: "Open Pinned Tab", comment: "Action label at the right of the selected command bar result, saying what Return does: opens the pinned tab.")
        case .action: String(localized: "Run", comment: "Action label at the right of the selected command bar result, saying what Return does: runs the command.")
        case .note: ""
        }
    }

    var isActionable: Bool { kind != .note }

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
        // The host is everything before the first of / ? #; the port comes off too.
        let hostEnd = lower.firstIndex { "/?#".contains($0) } ?? lower.endIndex
        let hostPart = String(lower[..<hostEnd])
        // An email address is something to search for, not a place to go. An @ further on is part of the page
        // ("youtube.com/@name").
        if hostPart.contains("@") { return nil }
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

    /// The address what you typed completes to, e.g. "wiki" → "wikipedia.org": sites from your history, weighed by
    /// how often and how lately you went, and the ones you keep at hand (open tabs, favorites, pinned tabs).
    /// `manager`: the browser window whose open tabs count, if there is one.
    static func inlineCompletion(for text: String, manager: TabManager?) -> InlineCompletion.Match? {
        let lower = text.lowercased()
        let bare = lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        guard !bare.isEmpty, InlineCompletion.looksLikeHost(lower) else { return nil }
        var found = HistoryStore.shared.completionSites(for: bare)
        if found.isEmpty { found = HistoryStore.shared.completionSites(for: bare, afterSubdomain: true) }
        var sites: [InlineCompletion.Site] = found.compactMap { entry, score in
            InlineCompletion.target(entry.url, wholePage: true).map { InlineCompletion.Site(url: $0, score: score) }
        }
        // Each place a site is kept at hand counts as much as a visit this week.
        let kept = (manager?.allTabs ?? []).compactMap(\.url) + Library.shared.favorites.map(\.url) + Library.shared.allBookmarks.map(\.0.url)
        // Whether its host or a shorter form of it matches is for `best` to say.
        for url in kept where HistoryStore.normalizedHost(url).contains(bare) {
            if let site = InlineCompletion.target(url, wholePage: false) { sites.append(InlineCompletion.Site(url: site, score: 1)) }
        }
        return InlineCompletion.best(for: text, among: InlineCompletion.merge(sites))
    }

    struct Action {
        let id: String
        let title: String
        let keywords: [String]
        let symbol: String
    }

    static let actions: [Action] = [
        Action(id: "clear-cache", title: String(localized: "Clear Cache…", comment: "A command in the command bar, named as in the menu bar."),
               keywords: ["clear", "cache", "empty", "reset", "refresh"], symbol: "arrow.clockwise"),
        Action(id: "clear-cookies", title: String(localized: "Clear Cookies…", comment: "A command in the command bar, named as in the menu bar."),
               keywords: ["clear", "cookies", "sign", "out", "logout", "reset", "data"], symbol: "trash"),
        Action(id: "settings", title: String(localized: "Settings", comment: "A command in the command bar, named as in the menu bar."),
               keywords: ["settings", "preferences", "options", "engine", "privacy", "extensions", "shortcuts"], symbol: "gearshape"),
        Action(id: "passwords", title: String(localized: "Passwords", comment: "A command in the command bar, named as in the menu bar."),
               keywords: ["passwords", "logins", "keychain", "accounts"], symbol: "key"),
        Action(id: "import", title: String(localized: "Import from Another Browser…", comment: "A command in the command bar, named as in the menu bar."),
               keywords: ["import", "bring", "move", "switch", "passwords", "bookmarks", "arc", "chrome", "safari", "firefox"], symbol: "square.and.arrow.down"),
        Action(id: "feedback", title: String(localized: "Send Feedback…", comment: "A command in the command bar, named as in the menu bar."),
               keywords: ["feedback", "send", "suggest", "idea", "contact", "email", "help"], symbol: "bubble.left"),
        Action(id: "report", title: String(localized: "Report a Problem…", comment: "A command in the command bar, named as in the menu bar."),
               keywords: ["report", "bug", "issue", "problem", "crash", "freeze", "broken", "help"], symbol: "exclamationmark.bubble"),
    ]

    /// What the bar needs to know about the window to offer only the commands that would do something.
    struct Context {
        struct Space { let id: UUID; let name: String }
        var isPrivate = false
        /// The page you're on has an address (a blank new tab doesn't).
        var hasPage = false
        var isPinned = false
        var isFavorite = false
        var inSplit = false
        /// Another tab, the last one you were on, can open beside this one.
        var canSplitWithRecent = false
        /// The page you're on is an ordinary tab, so it can move to another space.
        var canMove = false
        var hasOtherTabs = false
        var hasTabsBelow = false
        var canReopen = false
        var spaces: [Space] = []
        var currentSpaceID: UUID?
    }

    /// The commands about the page and window you're in, each named as in the menu bar, and only those that apply.
    static func contextActions(_ c: Context) -> [Action] {
        var list: [Action] = []
        if c.hasPage, !c.isPrivate, !c.isFavorite {
            list.append(c.isPinned
                ? Action(id: "unpin", title: String(localized: "Unpin Tab", comment: "A command in the command bar, named as in the menu bar."),
                         keywords: ["unpin", "pin", "tab", "remove"], symbol: "pin.slash")
                : Action(id: "pin", title: String(localized: "Pin Tab", comment: "A command in the command bar, named as in the menu bar."),
                         keywords: ["pin", "tab", "keep", "bookmark"], symbol: "pin"))
        }
        if c.hasPage, !c.isFavorite, c.isPinned || !c.isPrivate {
            list.append(Action(id: "favorite", title: String(localized: "Add to Favorites", comment: "A command in the command bar, named as in the menu bar."),
                               keywords: ["add", "favorites", "favourites", "star", "bookmark"], symbol: "star"))
        }
        if c.inSplit {
            list.append(Action(id: "separate", title: String(localized: "Separate Tabs", comment: "A command in the command bar, named as in the menu bar."),
                               keywords: ["separate", "tabs", "split", "unsplit", "view", "close"], symbol: "rectangle.split.2x1.slash"))
        } else if c.canSplitWithRecent {
            list.append(Action(id: "split", title: String(localized: "Open in Split View", comment: "A command in the command bar, named as in the menu bar."),
                               keywords: ["open", "split", "view", "side", "two"], symbol: "rectangle.split.2x1"))
        }
        if c.hasOtherTabs {
            list.append(Action(id: "close-others", title: String(localized: "Close Other Tabs", comment: "A command in the command bar, named as in the menu bar."),
                               keywords: ["close", "other", "tabs", "clean", "tidy"], symbol: "xmark.circle"))
        }
        if c.hasTabsBelow {
            list.append(Action(id: "close-below", title: String(localized: "Close Tabs Below", comment: "A command in the command bar, named as in the menu bar."),
                               keywords: ["close", "tabs", "below", "under"], symbol: "xmark.circle"))
        }
        if c.canReopen {
            list.append(Action(id: "reopen", title: String(localized: "Reopen Closed Tab", comment: "A command in the command bar, named as in the menu bar."),
                               keywords: ["reopen", "closed", "tab", "undo", "restore", "back"], symbol: "arrow.uturn.backward"))
        }
        // Spaces are kept for good; a private window keeps nothing and has one space.
        guard !c.isPrivate else { return list }
        list.append(Action(id: "new-space", title: String(localized: "New Space", comment: "A command in the command bar, named as in the menu bar."),
                           keywords: ["new", "space", "create", "add"], symbol: "plus.square"))
        for space in c.spaces where space.id != c.currentSpaceID {
            let name = space.name.lowercased().split(separator: " ").map(String.init)
            list.append(Action(id: "space:\(space.id.uuidString)", title: String(localized: "Switch to \(space.name)", comment: "A command in the command bar: goes to another space. The name is the space's."),
                               keywords: ["switch", "go", "space"] + name, symbol: "square.on.square"))
            if c.canMove {
                list.append(Action(id: "move:\(space.id.uuidString)", title: String(localized: "Move to \(space.name)", comment: "A command in the command bar: moves the tab to another space. The name is the space's."),
                                   keywords: ["move", "tab", "space", "send"] + name, symbol: "arrow.right.square"))
            }
        }
        return list
    }

    /// Whether every word you typed starts a word of the command's own name ("imp" for Import, "pin t" for Pin Tab),
    /// rather than only one of its hidden keywords. One or two characters found inside a page command's name (其他
    /// in 关闭其他标签页) don't count: it's listed after the search, so Return never closes tabs on a near miss.
    static func isNamed(_ action: Action, by words: [String]) -> Bool {
        let titleWords = action.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let inside = words.joined().count >= 3 || actions.contains { $0.id == action.id }
        return !words.isEmpty && words.allSatisfy { word in
            titleWords.contains { $0.hasPrefix(word) } || (namesFindCommands && inside && action.title.localizedCaseInsensitiveContains(word))
        }
    }

    /// The commands every word you typed starts a keyword of. The ones about this page and window (Pin Tab, Close
    /// Other Tabs) wait for three letters, so a site's first letter and Return never pins or closes anything.
    static func commands(for query: String, context: Context) -> [Action] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let pageCommands = contextActions(context)
        let candidates = (isEnough(query, for: (pageCommands + actions).map(\.title)) ? pageCommands : []) + actions
        return candidates.filter { action in
            words.allSatisfy { word in
                action.keywords.contains { $0.hasPrefix(word) } || (namesFindCommands && action.title.localizedCaseInsensitiveContains(word))
            }
        }
    }

    /// Whether what you typed is enough for the commands about this page and window. Three letters in Latin; in
    /// Chinese or Japanese a character or two already make a word, so two are enough, and one is when it starts
    /// just one command's name (固 for 固定标签页).
    static func isEnough(_ query: String, for names: [String]) -> Bool {
        if query.count >= 3 { return true }
        let typed = query.lowercased().filter { !$0.isWhitespace }
        guard !typed.isEmpty, typed.allSatisfy(isCJK) else { return false }
        if typed.count == 2 { return true }
        return typed.count == 1 && names.filter { $0.lowercased().hasPrefix(typed) }.count == 1
    }

    /// A Chinese character, kana or Hangul: one of these says about as much as a Latin word.
    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { s in
            s.properties.isIdeographic || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
        }
    }

    /// The keywords are English. With Zigzag in another language, what you type in it finds a command by its own
    /// name too (Chinese has no spaces to start words at, so anywhere in the name counts). In English, only the
    /// keywords do, as they always have.
    private static let namesFindCommands = !(Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("en")

    static func context(for manager: TabManager) -> Context {
        var c = Context()
        c.isPrivate = manager.isPrivate
        c.canReopen = manager.canReopenClosedTab
        c.spaces = Library.shared.spaces.map { Context.Space(id: $0.id, name: $0.name) }
        c.currentSpaceID = manager.currentSpaceID
        let tabs = manager.currentTabs
        guard let tab = manager.selectedTab else { return c }
        c.hasPage = tab.url != nil
        c.isFavorite = tab.isFavorite
        c.isPinned = tab.bookmarkID != nil && !tab.isFavorite
        c.inSplit = manager.split(for: tab) != nil
        c.canSplitWithRecent = splitPartner(for: tab, in: manager) != nil
        c.canMove = tab.bookmarkID == nil && tab.url != nil
        // On a pinned page or favorite, every tab is another tab, and all of them are below it.
        // Its split partner is part of it, as Close Other Tabs and Close Tabs Below count it.
        let partner = manager.partner(of: tab)
        let last = tabs.lastIndex { $0 === tab || $0 === partner }
        c.hasOtherTabs = tabs.contains { $0 !== tab && $0 !== partner }
        c.hasTabsBelow = tabs.count > (last.map { $0 + 1 } ?? 0)
        return c
    }

    /// The tab Open in Split View puts beside this one: the last other page you were on, in this space.
    static func splitPartner(for tab: Tab, in manager: TabManager) -> Tab? {
        guard tab.url != nil, manager.split(for: tab) == nil else { return nil }
        return manager.recentTabs.first { other in
            other !== tab && other.url != nil && other.spaceID == tab.spaceID && manager.split(for: other) == nil && manager.canSplit(tab, with: other)
        }
    }

    /// `manager`: the browser window whose tabs and commands are offered; with none (Zigzag Mini on its own), only
    /// pages to open and searches.
    static func results(for text: String, manager: TabManager?, suggestions: [String], editingCurrent: Bool, historyOnly: Bool) -> [CommandResult] {
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
                // No history yet: say what this is for rather than showing nothing.
                if results.isEmpty {
                    add(CommandResult(kind: .note, title: String(localized: "No history yet", comment: "The command bar searching history, when there is none yet."),
                                      detail: String(localized: "Pages you visit show up here", comment: "Under No history yet, in the command bar searching history."),
                                      symbol: "clock"), key: "empty-history")
                }
                return results
            }
            // Nothing typed yet: recent tabs, so switching is one keystroke away.
            for tab in (manager?.recentTabs ?? []).prefix(6) where tab !== manager?.selectedTab {
                guard let url = tab.url else { continue }
                add(CommandResult(kind: .switchTo(tab.id), title: tab.displayTitle, detail: displayURL(url), icon: tab.favicon),
                    key: TabManager.normalize(url))
            }
            return results
        }

        let words = query.lowercased().split(separator: " ").map(String.init)
        let engine = Library.shared.searchEngine

        // What you typed always comes first, as a search or the address it names, so Return never does something
        // else: someone typing "settings" may want to search the web for it. Zigzag's own commands follow, the ones
        // you've named ("import", "pin tab") right under it, then those the words only touch through a keyword.
        let matched = historyOnly ? [] : manager.map { commands(for: query, context: context(for: $0)) } ?? []
        let named = matched.filter { Self.isNamed($0, by: words) }
        func addActions(_ list: [Action]) {
            for action in list {
                // Split View says which page it puts beside this one.
                let partner = action.id == "split" ? manager.flatMap { m in m.selectedTab.flatMap { splitPartner(for: $0, in: m) } } : nil
                add(CommandResult(kind: .action(action.id), title: action.title, detail: partner.map { String(localized: "with \($0.displayTitle)", comment: "Under the command bar's Open in Split View command: the page it opens beside this one. The title is that page's.") } ?? "",
                                  symbol: action.symbol), key: "action:\(action.id)")
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
        addActions(named)
        addActions(matched.filter { !Self.isNamed($0, by: words) })

        if !historyOnly {
            var tabCount = 0
            for tab in (manager?.recentTabs ?? []) + (manager?.allTabs ?? []) where tabCount < 3 {
                guard let url = tab.url, matches(words, tab.displayTitle, url.absoluteString) else { continue }
                let key = TabManager.normalize(url)
                guard !seen.contains(key) else { continue }
                add(CommandResult(kind: .switchTo(tab.id), title: tab.displayTitle, detail: displayURL(url), icon: tab.favicon), key: key)
                tabCount += 1
            }
            var bookmarkCount = 0
            // Favorites first: they're the sites you go to most.
            let favorites = Set(Library.shared.favorites.map(\.id))
            for bookmark in Library.shared.favorites + Library.shared.allBookmarks.map(\.0) where bookmarkCount < 3 {
                guard matches(words, bookmark.title, bookmark.url.absoluteString) else { continue }
                let key = TabManager.normalize(bookmark.url)
                guard !seen.contains(key) else { continue }
                add(CommandResult(kind: .bookmark(bookmark.id), title: bookmark.title, detail: displayURL(bookmark.url),
                                  icon: FaviconStore.shared.cachedIcon(for: bookmark.url), isFavorite: favorites.contains(bookmark.id)), key: key)
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
                                  detail: space.map { String(localized: "Archived from \($0)", comment: "Under a command bar result for a tab that tidied itself away. The name is the space it was in.") }
                                      ?? String(localized: "Archived", comment: "Under a command bar result for a tab that tidied itself away."),
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

        // Searching history and nothing matches: never a blank bar. Say so, with the web search one Return away.
        if historyOnly, results.isEmpty {
            add(CommandResult(kind: .search(query), title: String(localized: "Search the web for “\(query)”", comment: "Command bar result when nothing in history matches. The query is what was typed."),
                              detail: String(localized: "Nothing in your history matches", comment: "Under the command bar's search-the-web result, when nothing in history matches."),
                              symbol: "magnifyingglass"), key: "search:\(query)")
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
    /// In a private window: suggestions go through a session of their own, so the search engine can't tie them to
    /// your other browsing.
    var isPrivate = false
    private lazy var privateSession = URLSession(configuration: .ephemeral)
    /// Everyday windows' suggestions: no cookies and no cache either, so what you type can't be tied to you by a
    /// cookie the engine set, only your text and the address it came from.
    private static let session = URLSession(configuration: .ephemeral)

    /// On by default. Off, nothing you type in the command bar leaves the Mac for suggestions.
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "SearchSuggestions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SearchSuggestions") }
    }

    /// Where a query would be sent for suggestions, or nil when it stays on the Mac.
    static func url(for query: String, engine: SearchEngine, isOn: Bool) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard isOn, trimmed.count >= 2, CommandRanker.url(from: trimmed) == nil else { return nil }
        return engine.suggestionsURL(trimmed)
    }

    func fetch(_ query: String, completion: @escaping ([String]) -> Void) {
        task?.cancel()
        guard let url = Self.url(for: query, engine: Library.shared.searchEngine, isOn: Self.isOn) else { completion([]); return }
        let session = isPrivate ? privateSession : Self.session
        task = Task {
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            guard let (data, _) = try? await session.data(from: url), !Task.isCancelled else { return }
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

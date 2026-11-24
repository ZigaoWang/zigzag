import Foundation
import Network

/// Where a live folder's pages come from: a feed (or a site that links to one), or a GitHub list for a username.
nonisolated struct LiveSource: Codable, Equatable, Sendable {
    /// What was typed: a feed's address or a site's.
    var address: URL?
    /// The feed found there: the address itself, or the one its page links to. Nil until it's been looked up.
    var feed: URL?
    var gitHub: GitHubList?
    var user: String?

    static func feed(_ address: URL, found: URL? = nil) -> LiveSource { LiveSource(address: address, feed: found) }
    static func gitHub(_ list: GitHubList, user: String) -> LiveSource { LiveSource(gitHub: list, user: user) }

    /// A source that can be fetched at all.
    var isComplete: Bool {
        if gitHub != nil { return user.map(GitHubList.isUsername) ?? false }
        return address != nil
    }

    /// The site the folder is for, for its menu and name.
    var siteName: String? {
        if gitHub != nil { return "github.com" }
        guard let host = (feed ?? address)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// One page a live folder shows: the feed entry it is, and the pinned page that shows it.
nonisolated struct LiveItem: Codable, Equatable, Sendable {
    var key: String
    var url: URL
    /// As the feed calls it: renaming the row doesn't change this, and a new name from the feed renames the row.
    var title: String
    var bookmarkID: UUID
}

/// A folder that fills itself from its source (`LiveFolders`). Its pages are pinned pages like any folder's, kept in
/// the space's list, so they open, show and save as pinned pages do; the folder only takes the ones its source gives.
nonisolated struct LiveFolder: Codable, Equatable, Sendable {
    var source: LiveSource
    /// The most pages it shows: 10, 25 or 50.
    var limit: Int = LiveFolder.defaultLimit
    /// Named after the feed until you name it yourself.
    var namedByFeed = false
    /// Newest first, at most `limit`.
    var items: [LiveItem] = []

    static let limits = [10, 25, 50]
    static let defaultLimit = 25

    init(source: LiveSource, limit: Int = LiveFolder.defaultLimit, namedByFeed: Bool = false, items: [LiveItem] = []) {
        self.source = source
        self.limit = Self.limits.contains(limit) ? limit : Self.defaultLimit
        self.namedByFeed = namedByFeed
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case source, limit, namedByFeed, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(LiveSource.self, forKey: .source)
        let limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        self.limit = Self.limits.contains(limit) ? limit : Self.defaultLimit
        namedByFeed = try c.decodeIfPresent(Bool.self, forKey: .namedByFeed) ?? false
        items = try c.decodeIfPresent([LiveItem].self, forKey: .items) ?? []
    }
}

/// Why a live folder couldn't refresh, said in its menu.
nonisolated enum LiveProblem: Codable, Equatable, Sendable {
    case status(Int)
    case notAFeed
    case noFeedOnPage
    case tooBig
    case unreachable
    case noSuchUser
    case rateLimited

    var message: String {
        switch self {
        case .status(404), .status(410): String(localized: "The feed isn’t there any more.", comment: "Why a live folder couldn't refresh, in its menu in the sidebar.")
        case .status(let code): String(localized: "The site answered with error \(code).", comment: "Why a live folder couldn't refresh, in its menu in the sidebar. The number is the HTTP status, like 500.")
        case .notAFeed: String(localized: "This address isn’t a feed.", comment: "Why a live folder couldn't refresh, in its menu in the sidebar, and under the address in the New Live Folder sheet.")
        case .noFeedOnPage: String(localized: "This page doesn’t link to a feed.", comment: "Why a live folder couldn't refresh, in its menu in the sidebar, and under the address in the New Live Folder sheet.")
        case .tooBig: String(localized: "The feed is too large.", comment: "Why a live folder couldn't refresh, in its menu in the sidebar: the feed is over 5 MB.")
        case .unreachable: String(localized: "The site can’t be reached.", comment: "Why a live folder couldn't refresh, in its menu in the sidebar, and under the address in the New Live Folder sheet.")
        case .noSuchUser: String(localized: "GitHub doesn’t know this username.", comment: "Why a live folder of GitHub pull requests or issues couldn't refresh, in its menu in the sidebar.")
        case .rateLimited: String(localized: "GitHub asked Zigzag to wait. It tries again later.", comment: "Why a live folder of GitHub pull requests or issues couldn't refresh, in its menu in the sidebar: too many requests.")
        }
    }
}

/// When a live folder is fetched next.
nonisolated enum LiveSchedule {
    /// Every half hour.
    static let interval: TimeInterval = 30 * 60
    /// In Low Power Mode, no more often than hourly.
    static let lowPowerInterval: TimeInterval = 60 * 60
    /// After a failure: 5 minutes, then twice as long each time, up to 6 hours.
    static let firstRetry: TimeInterval = 5 * 60
    static let longestRetry: TimeInterval = 6 * 60 * 60

    static func next(after now: Date, failures: Int, lowPower: Bool, retryAfter: TimeInterval? = nil) -> Date {
        var wait = failures <= 0 ? interval : min(firstRetry * pow(2, Double(min(failures, 20) - 1)), longestRetry)
        if lowPower { wait = max(wait, lowPowerInterval) }
        if let retryAfter, retryAfter > 0 { wait = max(wait, min(retryAfter, 24 * 60 * 60)) }
        return now.addingTimeInterval(wait)
    }

    /// Unread after a fetch: what was unread and is still there, and every key never seen before. `seen` remembers
    /// the keys shown so far (the newest few thousand), so a page that comes back isn't new again.
    static func unread(_ unread: Set<String>, seen: [String], keys: [String]) -> (unread: Set<String>, seen: [String]) {
        let known = Set(seen)
        let fresh = keys.filter { !known.contains($0) }
        let now = unread.intersection(keys).union(fresh)
        return (now, Array((seen + fresh).suffix(4000)))
    }
}

/// A live folder's fetch, off the main thread: an ephemeral session (no cookies, no cache, nothing that ties it to a
/// profile), Zigzag's user agent, conditional requests, and at most `maxBytes` read.
nonisolated final class LiveFetcher: Sendable {
    static let maxBytes = 5_000_000
    let session: URLSession

    struct Response: Sendable {
        var status: Int
        var url: URL
        var headers: [String: String]
        var body: Data
        func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }

    enum Failure: Error, Equatable { case tooBig, unreachable, offline }

    static func configuration(userAgent: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.dropsCookies()
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return config
    }

    init(configuration: URLSessionConfiguration) { session = URLSession(configuration: configuration) }

    func get(_ url: URL, headers: [String: String]) async throws(Failure) -> Response {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let download = Download(limit: Self.maxBytes)
        let task = session.dataTask(with: request)
        task.delegate = download
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                download.start(continuation)
                task.resume()
            }
        } onCancel: { task.cancel() }
        switch result {
        case .success(let (http, body)):
            var fields: [String: String] = [:]
            for (key, value) in http.allHeaderFields { if let key = key as? String { fields[key] = "\(value)" } }
            return Response(status: http.statusCode, url: http.url ?? url, headers: fields, body: body)
        case .failure(let failure):
            throw failure
        }
    }

    /// One request's body, given up past `limit` bytes as they arrive.
    private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let lock = NSLock()
        private var body = Data()
        private var response: HTTPURLResponse?
        private var tooBig = false
        private var done: CheckedContinuation<Result<(HTTPURLResponse, Data), Failure>, Never>?

        init(limit: Int) { self.limit = limit }

        func start(_ continuation: CheckedContinuation<Result<(HTTPURLResponse, Data), Failure>, Never>) { lock.withLock { done = continuation } }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let over = response.expectedContentLength > limit
            lock.withLock {
                self.response = response as? HTTPURLResponse
                if over { tooBig = true }
            }
            completionHandler(over ? .cancel : .allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let over = lock.withLock { () -> Bool in
                guard !tooBig else { return true }
                if body.count + data.count > limit { tooBig = true; body = Data(); return true }
                body.append(data)
                return false
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, result) = lock.withLock { () -> (CheckedContinuation<Result<(HTTPURLResponse, Data), Failure>, Never>?, Result<(HTTPURLResponse, Data), Failure>) in
                defer { done = nil }
                if tooBig { return (done, .failure(.tooBig)) }
                if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) { return (done, .failure(.offline)) }
                guard error == nil, let response else { return (done, .failure(.unreachable)) }
                return (done, .success((response, body)))
            }
            continuation?.resume(returning: result)
        }
    }
}

/// One fetch of a live folder's source, and what came of it.
nonisolated enum LiveRefresh {
    struct Validators: Codable, Equatable, Sendable {
        var etag: String?
        var lastModified: String?
    }

    enum Outcome: Equatable, Sendable {
        /// Nothing new since last time (304).
        case unchanged
        /// `feed`: the feed's address, when it was found on the source's page.
        case entries([LiveFeed.Entry], title: String?, feed: URL?, validators: Validators)
        case failed(LiveProblem, retryAfter: TimeInterval?)
        case offline
    }

    static let feedAccept = "application/rss+xml, application/atom+xml, application/rdf+xml;q=0.9, application/xml;q=0.8, text/xml;q=0.8, */*;q=0.5"

    static func run(_ source: LiveSource, validators: Validators, limit: Int, fetcher: LiveFetcher, now: Date = Date()) async -> Outcome {
        do throws(LiveFetcher.Failure) {
            if let list = source.gitHub, let user = source.user { return try await gitHub(list, user: user, validators: validators, limit: limit, fetcher: fetcher, now: now) }
            guard let address = source.feed ?? source.address else { return .failed(.notAFeed, retryAfter: nil) }
            // The validators belong to the feed, so they go only with it.
            var headers = ["Accept": feedAccept]
            if source.feed != nil {
                if let etag = validators.etag { headers["If-None-Match"] = etag }
                if let modified = validators.lastModified { headers["If-Modified-Since"] = modified }
            }
            let response = try await fetcher.get(address, headers: headers)
            if response.status == 304 { return .unchanged }
            if let failure = failure(response, now: now) { return failure }
            if let feed = LiveFeedParser.parse(response.body, base: response.url) {
                return .entries(feed.entries, title: feed.title, feed: source.feed == nil ? address : nil, validators: Self.validators(of: response))
            }
            // A site's page: the feed it links to, once.
            guard source.feed == nil, !FeedDiscovery.looksLikeFeed(response.body) else { return .failed(.notAFeed, retryAfter: nil) }
            let html = String(decoding: response.body, as: UTF8.self)
            guard let found = FeedDiscovery.feeds(inHTML: html, base: response.url).first else { return .failed(.noFeedOnPage, retryAfter: nil) }
            let feedResponse = try await fetcher.get(found, headers: ["Accept": feedAccept])
            if let failure = failure(feedResponse, now: now) { return failure }
            guard let feed = LiveFeedParser.parse(feedResponse.body, base: feedResponse.url) else { return .failed(.notAFeed, retryAfter: nil) }
            return .entries(feed.entries, title: feed.title, feed: found, validators: Self.validators(of: feedResponse))
        } catch .offline {
            return .offline
        } catch .tooBig {
            return .failed(.tooBig, retryAfter: nil)
        } catch {
            return .failed(.unreachable, retryAfter: nil)
        }
    }

    private static func gitHub(_ list: GitHubList, user: String, validators: Validators, limit: Int, fetcher: LiveFetcher, now: Date) async throws(LiveFetcher.Failure) -> Outcome {
        var headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let etag = validators.etag { headers["If-None-Match"] = etag }
        let response = try await fetcher.get(list.url(for: user, count: limit), headers: headers)
        if response.status == 304 { return .unchanged }
        // An unknown user fails the search's validation.
        if response.status == 422 { return .failed(.noSuchUser, retryAfter: nil) }
        if let failure = failure(response, now: now) { return failure }
        guard let entries = GitHubList.entries(response.body) else { return .failed(.notAFeed, retryAfter: nil) }
        return .entries(entries, title: nil, feed: nil, validators: Self.validators(of: response))
    }

    private static func validators(of response: LiveFetcher.Response) -> Validators {
        Validators(etag: response.header("ETag"), lastModified: response.header("Last-Modified"))
    }

    /// A response that isn't a success, as a failure, with how long the server asked to wait.
    static func failure(_ response: LiveFetcher.Response, now: Date) -> Outcome? {
        guard !(200..<300).contains(response.status) else { return nil }
        var wait: TimeInterval?
        if let after = response.header("Retry-After") {
            wait = TimeInterval(after.trimmingCharacters(in: .whitespaces)) ?? FeedDates.parse(after).map { $0.timeIntervalSince(now) }
        }
        let limited = response.status == 429 || (response.status == 403 && response.header("X-RateLimit-Remaining") == "0")
        if limited, wait == nil, let reset = response.header("X-RateLimit-Reset").flatMap(TimeInterval.init) {
            wait = reset - now.timeIntervalSince1970
        }
        return .failed(limited ? .rateLimited : .status(response.status), retryAfter: wait)
    }
}

/// Keeps live folders filled: each one's source fetched in the background every half hour (`LiveSchedule`), and its
/// unread pages. The folders and their pages are in the library, saved with the other pins; what changes with every
/// fetch or click (unread pages, validators, failures) is kept here, in its own file, so it never stands in the way
/// of undoing a change to the pins.
final class LiveFolders {
    static let shared = LiveFolders()

    struct State: Codable, Equatable {
        var unread: Set<String> = []
        var seen: [String] = []
        var validators = LiveRefresh.Validators()
        var checked: Date?
        var next: Date?
        var failures = 0
        var problem: LiveProblem?
    }

    /// Fires when unread pages or a folder's state change.
    let changed = Signal<Void>()
    private(set) var states: [UUID: State] = [:]
    private let file: URL
    private let library: Library
    var fetcher: LiveFetcher
    /// The time, for tests.
    var now: () -> Date = Date.init
    var isLowPower: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    private(set) var isOnline = true
    private var running: Set<UUID> = []
    private var timer: Timer?
    private var monitor: NWPathMonitor?
    private let saveDebouncer = Debouncer(delay: 1, maxWait: 5)

    init(file: URL = Paths.file("LiveFolders.json"), library: Library = .shared, fetcher: LiveFetcher? = nil) {
        self.file = file
        self.library = library
        self.fetcher = fetcher ?? LiveFetcher(configuration: LiveFetcher.configuration(userAgent: WebKitSetup.userAgent))
        states = JSONStore.load([UUID: State].self, from: file) ?? [:]
    }

    /// Starts the half-hourly fetches, and one now for any folder that's due.
    func start() {
        guard timer == nil else { return }
        let known = Set(library.liveFolders.map(\.id))
        // Folders gone since the last run (deleted, then not undone before quitting).
        if states.keys.contains(where: { !known.contains($0) }) { states = states.filter { known.contains($0.key) }; save() }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDue() } }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                if online { self.refreshDue() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.zigzag.live-folders", qos: .utility))
        self.monitor = monitor
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.refreshDue() }
    }

    func state(_ folderID: UUID) -> State { states[folderID] ?? State() }

    // MARK: Unread

    func isUnread(bookmark id: UUID) -> Bool {
        guard let (folder, item) = library.liveItem(forBookmark: id) else { return false }
        return states[folder]?.unread.contains(item.key) == true
    }

    func unreadCount(_ folderID: UUID) -> Int {
        guard let folder = library.folder(folderID)?.live, let unread = states[folderID]?.unread, !unread.isEmpty else { return 0 }
        return folder.items.filter { unread.contains($0.key) }.count
    }

    /// Opened: it's read.
    func markRead(bookmark id: UUID) { setRead(bookmark: id, true) }

    func setRead(bookmark id: UUID, _ read: Bool) {
        guard let (folder, item) = library.liveItem(forBookmark: id) else { return }
        var state = self.state(folder)
        guard state.unread.contains(item.key) == read else { return }
        if read { state.unread.remove(item.key) } else { state.unread.insert(item.key) }
        states[folder] = state
        save()
        changed.send()
    }

    func markAllRead(_ folderID: UUID) {
        guard var state = states[folderID], !state.unread.isEmpty else { return }
        state.unread = []
        states[folderID] = state
        save()
        changed.send()
    }

    // MARK: Fetching

    /// Every folder whose time has come, one after another, unless the Mac is offline.
    func refreshDue() {
        guard isOnline else { return }
        let due = library.liveFolders.filter { (states[$0.id]?.next ?? .distantPast) <= now() }
        guard !due.isEmpty else { return }
        Task { for folder in due { await refresh(folder.id) } }
    }

    func refreshNow(_ folderID: UUID) { Task { await refresh(folderID) } }

    /// A new source (the folder was edited): start over.
    func reset(_ folderID: UUID) {
        states[folderID] = State()
        save()
        changed.send()
    }

    /// Fetches the folder's source and fills it with what came.
    func refresh(_ folderID: UUID) async {
        guard let live = library.folder(folderID)?.live, live.source.isComplete, running.insert(folderID).inserted else { return }
        defer { running.remove(folderID) }
        let before = state(folderID)
        let outcome = await LiveRefresh.run(live.source, validators: before.validators, limit: live.limit, fetcher: fetcher, now: now())
        // Edited or deleted while it was fetching: what came is for a source it no longer has.
        guard let current = library.folder(folderID)?.live, current.source == live.source else { return }
        apply(outcome, to: folderID)
    }

    func apply(_ outcome: LiveRefresh.Outcome, to folderID: UUID) {
        guard let live = library.folder(folderID)?.live else { return }
        var state = self.state(folderID)
        let now = now()
        switch outcome {
        case .unchanged:
            state.failures = 0
            state.problem = nil
            state.checked = now
            state.next = LiveSchedule.next(after: now, failures: 0, lowPower: isLowPower())
        case .entries(let entries, let title, let feed, let validators):
            let kept = Array(entries.prefix(live.limit))
            library.setLiveItems(kept.map { LiveItem(key: $0.key, url: $0.url, title: $0.title, bookmarkID: UUID()) }, ofFolder: folderID,
                                 feedTitle: title, foundFeed: feed)
            (state.unread, state.seen) = LiveSchedule.unread(state.unread, seen: state.seen, keys: kept.map(\.key))
            state.validators = validators
            state.failures = 0
            state.problem = nil
            state.checked = now
            state.next = LiveSchedule.next(after: now, failures: 0, lowPower: isLowPower())
        case .failed(let problem, let wait):
            state.failures += 1
            state.problem = problem
            state.next = LiveSchedule.next(after: now, failures: state.failures, lowPower: isLowPower(), retryAfter: wait)
        case .offline:
            // Not the source's fault: tried again when the Mac is back online, or in a few minutes.
            state.next = now.addingTimeInterval(LiveSchedule.firstRetry)
        }
        states[folderID] = state
        save()
        changed.send()
    }

    /// What typing an address in the New Live Folder sheet finds: the feed and its name, or why there's none.
    enum Lookup: Equatable { case found(feed: URL, title: String?), problem(LiveProblem) }

    func lookUp(_ address: URL) async -> Lookup {
        switch await LiveRefresh.run(.feed(address), validators: .init(), limit: 1, fetcher: fetcher, now: now()) {
        case .entries(_, let title, let feed, _): .found(feed: feed ?? address, title: title)
        case .failed(let problem, _): .problem(problem)
        case .offline, .unchanged: .problem(.unreachable)
        }
    }

    private func save() {
        saveDebouncer.call { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        saveDebouncer.cancel()
        JSONStore.save(states, to: file)
    }
}

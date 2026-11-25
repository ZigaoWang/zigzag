import Foundation
import Testing
@testable import Zigzag

/// Live folders: when they fetch, how politely, what a fetch does to the folder's pages and their dots, and what's
/// kept on disk. Every fetch goes to a stand-in server (`Server`); nothing here reaches the network.
@Suite(.serialized)
@MainActor
struct LiveFoldersTests {
    nonisolated final class Server: URLProtocol, @unchecked Sendable {
        struct Answer { var status = 200; var headers: [String: String] = [:]; var body = Data() }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var answers: [String: Answer] = [:]
        nonisolated(unsafe) private static var heard: [URLRequest] = []

        static func answer(_ url: String, _ answer: Answer) { lock.withLock { answers[url] = answer } }
        static func reset() { lock.withLock { answers = [:]; heard = [] } }
        static var requests: [URLRequest] { lock.withLock { heard } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            let answer = Self.lock.withLock { () -> Answer? in
                Self.heard.append(request)
                return Self.answers[url.absoluteString]
            } ?? Answer(status: 404)
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var sent = 0
            while sent < answer.body.count {
                let end = min(sent + 256_000, answer.body.count)
                client?.urlProtocol(self, didLoad: answer.body.subdata(in: sent..<end))
                sent = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static func fetcher() -> LiveFetcher {
        let config = LiveFetcher.configuration(userAgent: "Zigzag tests")
        config.protocolClasses = [Server.self]
        return LiveFetcher(configuration: config)
    }

    private static func rss(_ items: [(String, String)], title: String = "Example") -> Data {
        let entries = items.map { "<item><title>\($0.1)</title><link>https://example.com/\($0.0)</link><guid>\($0.0)</guid></item>" }.joined()
        return Data("<rss version=\"2.0\"><channel><title>\(title)</title>\(entries)</channel></rss>".utf8)
    }

    /// A space of its own with a live folder in it, and a LiveFolders that keeps its state in a file of its own; the
    /// library is put back as it was afterwards.
    private func withFolder(_ source: LiveSource, limit: Int = 25, namedByFeed: Bool = false,
                            _ body: (LiveFolders, BookmarkFolder, UUID) async throws -> Void) async rethrows {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        Server.reset()
        let space = Library.shared.addSpace(name: "Live").id
        let folder = Library.shared.addLiveFolder(named: "Feed", source: source, limit: limit, namedByFeed: namedByFeed, in: space)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LiveFolders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let live = LiveFolders(file: file, library: .shared, fetcher: Self.fetcher())
        live.isLowPower = { false }
        try await body(live, folder, space)
    }

    private func titles(_ folder: UUID) -> [String] {
        Library.shared.allBookmarkIDs(inFolder: folder).compactMap { Library.shared.bookmark($0)?.title }
    }

    // MARK: Schedule

    @Test func itWearsItsSitesIcon() throws {
        #expect(LiveSource.gitHub(.issues, user: "octocat").iconSite?.absoluteString == "https://github.com/")
        let typed = LiveSource.feed(try #require(URL(string: "https://example.com/blog")), found: URL(string: "https://feeds.example.net/x.xml"))
        #expect(typed.iconSite?.absoluteString == "https://example.com/")
        #expect(LiveSource.feed(try #require(URL(string: "http://localhost:8080/feed.xml"))).iconSite?.absoluteString == "http://localhost:8080/")
        #expect(LiveSource().iconSite == nil)
    }

    @Test func fetchesEveryHalfHourAndBacksOffAfterFailures() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func wait(_ failures: Int, lowPower: Bool = false, retryAfter: TimeInterval? = nil) -> TimeInterval {
            LiveSchedule.next(after: now, failures: failures, lowPower: lowPower, retryAfter: retryAfter).timeIntervalSince(now)
        }
        #expect(wait(0) == 30 * 60)
        #expect(wait(1) == 5 * 60)
        #expect(wait(2) == 10 * 60)
        #expect(wait(3) == 20 * 60)
        #expect(wait(8) == 6 * 60 * 60)
        #expect(wait(400) == 6 * 60 * 60)
        // Low Power Mode: no more often than hourly.
        #expect(wait(0, lowPower: true) == 60 * 60)
        #expect(wait(1, lowPower: true) == 60 * 60)
        // A server's Retry-After counts when it's longer.
        #expect(wait(1, retryAfter: 2 * 60 * 60) == 2 * 60 * 60)
        #expect(wait(1, retryAfter: 10) == 5 * 60)
    }

    @Test func newPagesAreUnreadOnceAndStayReadWhenTheyComeBack() {
        var (unread, seen) = LiveSchedule.unread([], seen: [], keys: ["a", "b"])
        #expect(unread == ["a", "b"])
        unread.remove("a")
        (unread, seen) = LiveSchedule.unread(unread, seen: seen, keys: ["c", "a", "b"])
        #expect(unread == ["b", "c"])
        // b fell out of the feed and came back: still unread, as it was; a came back read.
        (unread, seen) = LiveSchedule.unread(unread, seen: seen, keys: ["c"])
        #expect(unread == ["c"])
        (unread, seen) = LiveSchedule.unread(unread, seen: seen, keys: ["a", "b", "c"])
        #expect(unread == ["c"])
        #expect(seen == ["a", "b", "c"])
    }

    // MARK: Fetching

    @Test func aFetchFillsTheFolderNewestFirstWithDots() async throws {
        let feed = URL(string: "https://example.com/feed.xml")!
        try await withFolder(.feed(feed, found: feed)) { live, folder, _ in
            Server.answer(feed.absoluteString, .init(headers: ["ETag": "\"v1\"", "Last-Modified": "Mon, 02 Nov 2026 08:46:40 GMT"],
                                                     body: Self.rss([("2", "Two"), ("1", "One")])))
            await live.refresh(folder.id)
            #expect(titles(folder.id) == ["Two", "One"])
            #expect(live.unreadCount(folder.id) == 2)
            let state = live.state(folder.id)
            #expect(state.validators == .init(etag: "\"v1\"", lastModified: "Mon, 02 Nov 2026 08:46:40 GMT"))
            #expect(state.problem == nil && state.failures == 0)
            #expect(state.next == state.checked.map { $0.addingTimeInterval(LiveSchedule.interval) })
            // Never with cookies or the profile's session: an ephemeral session of its own.
            #expect(live.fetcher.session.configuration.httpCookieStorage == nil)
            #expect(live.fetcher.session.configuration.httpShouldSetCookies == false)
            #expect(live.fetcher.session.configuration.urlCache == nil)

            // Opened: read.
            let first = try #require(Library.shared.allBookmarkIDs(inFolder: folder.id).first)
            live.markRead(bookmark: first)
            #expect(live.unreadCount(folder.id) == 1)
            #expect(!live.isUnread(bookmark: first))
            live.markAllRead(folder.id)
            #expect(live.unreadCount(folder.id) == 0)
        }
    }

    /// The second fetch asks only for what changed since the first; a 304 changes nothing in the pins.
    @Test func fetchesAgainOnlyForWhatChanged() async throws {
        let feed = URL(string: "https://example.com/conditional.xml")!
        try await withFolder(.feed(feed, found: feed)) { live, folder, _ in
            Server.answer(feed.absoluteString, .init(headers: ["ETag": "\"abc\"", "Last-Modified": "Tue, 03 Nov 2026 09:00:00 GMT"],
                                                     body: Self.rss([("1", "One")])))
            await live.refresh(folder.id)
            #expect(Server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
            let pins = Library.shared.snapshot
            Server.answer(feed.absoluteString, .init(status: 304))
            await live.refresh(folder.id)
            let asked = try #require(Server.requests.last)
            #expect(asked.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
            #expect(asked.value(forHTTPHeaderField: "If-Modified-Since") == "Tue, 03 Nov 2026 09:00:00 GMT")
            #expect(Library.shared.snapshot == pins)
            #expect(titles(folder.id) == ["One"])
            #expect(live.state(folder.id).problem == nil)
        }
    }

    @Test func aFailureIsSaidInTheMenuAndTriedLaterAndLater() async throws {
        let feed = URL(string: "https://example.com/broken.xml")!
        try await withFolder(.feed(feed, found: feed)) { live, folder, _ in
            Server.answer(feed.absoluteString, .init(status: 500))
            let clock = Date(timeIntervalSince1970: 2_000_000)
            live.now = { clock }
            await live.refresh(folder.id)
            #expect(live.state(folder.id).problem == .status(500))
            #expect(live.state(folder.id).next == clock.addingTimeInterval(5 * 60))
            await live.refresh(folder.id)
            #expect(live.state(folder.id).failures == 2)
            #expect(live.state(folder.id).next == clock.addingTimeInterval(10 * 60))
            #expect(!LiveProblem.status(500).message.isEmpty)
            // The site is back: the problem goes.
            Server.answer(feed.absoluteString, .init(body: Self.rss([("1", "One")])))
            await live.refresh(folder.id)
            #expect(live.state(folder.id).problem == nil)
            #expect(live.state(folder.id).failures == 0)

            // Gone for good.
            Server.answer(feed.absoluteString, .init(status: 404))
            await live.refresh(folder.id)
            #expect(live.state(folder.id).problem == .status(404))
            #expect(titles(folder.id) == ["One"])
        }
    }

    @Test func aFeedOverFiveMegabytesIsLeftUnread() async throws {
        let feed = URL(string: "https://example.com/huge.xml")!
        try await withFolder(.feed(feed, found: feed)) { live, folder, _ in
            Server.answer(feed.absoluteString, .init(body: Data(repeating: 0x20, count: LiveFetcher.maxBytes + 1)))
            await live.refresh(folder.id)
            #expect(live.state(folder.id).problem == .tooBig)
            #expect(titles(folder.id).isEmpty)
        }
    }

    /// A site's address: its page's feed is found and fetched, kept as the folder's feed, and names the folder.
    @Test func aSitesAddressFindsItsFeed() async throws {
        let site = URL(string: "https://example.com/")!
        try await withFolder(.feed(site), namedByFeed: true) { live, folder, _ in
            Server.answer(site.absoluteString, .init(headers: ["Content-Type": "text/html"],
                                                     body: Data("<html><head><link rel=\"alternate\" type=\"application/atom+xml\" href=\"/atom\"></head></html>".utf8)))
            Server.answer("https://example.com/atom", .init(body: Data("""
            <feed xmlns="http://www.w3.org/2005/Atom"><title>Example Journal</title>
            <entry><id>1</id><title>Hello</title><link href="/hello"/><updated>2026-11-01T00:00:00Z</updated></entry></feed>
            """.utf8)))
            await live.refresh(folder.id)
            #expect(Library.shared.folder(folder.id)?.live?.source.feed == URL(string: "https://example.com/atom"))
            #expect(Library.shared.folder(folder.id)?.name == "Example Journal")
            #expect(titles(folder.id) == ["Hello"])
            #expect(await live.lookUp(site) == .found(feed: URL(string: "https://example.com/atom")!, title: "Example Journal"))

            Server.answer("https://example.com/plain", .init(body: Data("<html><head></head><body>No feed</body></html>".utf8)))
            #expect(await live.lookUp(URL(string: "https://example.com/plain")!) == .problem(.noFeedOnPage))
        }
    }

    @Test func gitHubListsComeFromItsSearchAndWaitWhenAsked() async throws {
        try await withFolder(.gitHub(.pullRequests, user: "octocat")) { live, folder, _ in
            let url = GitHubList.pullRequests.url(for: "octocat", count: 25).absoluteString
            Server.answer(url, .init(headers: ["ETag": "W/\"gh\""], body: Data("""
            {"items": [{"html_url": "https://github.com/a/b/pull/7", "title": "Make it faster", "updated_at": "2026-11-02T00:00:00Z"}]}
            """.utf8)))
            await live.refresh(folder.id)
            #expect(titles(folder.id) == ["Make it faster"])
            let asked = try #require(Server.requests.last)
            #expect(asked.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")

            let clock = Date(timeIntervalSince1970: 3_000_000)
            live.now = { clock }
            Server.answer(url, .init(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(clock.timeIntervalSince1970) + 3 * 60 * 60)"]))
            await live.refresh(folder.id)
            #expect(Server.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "W/\"gh\"")
            #expect(live.state(folder.id).problem == .rateLimited)
            #expect(live.state(folder.id).next == clock.addingTimeInterval(3 * 60 * 60))
            #expect(titles(folder.id) == ["Make it faster"])

            Server.answer(url, .init(status: 422))
            await live.refresh(folder.id)
            #expect(live.state(folder.id).problem == .noSuchUser)
        }
    }

    /// Offline isn't the feed's fault: no failure counted, tried again soon.
    @Test func offlineCountsNoFailure() {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Live").id
        let folder = Library.shared.addLiveFolder(named: "Feed", source: .feed(URL(string: "https://example.com/f")!), limit: 25, namedByFeed: false, in: space)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LiveFolders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let live = LiveFolders(file: file, library: .shared, fetcher: Self.fetcher())
        let clock = Date(timeIntervalSince1970: 4_000_000)
        live.now = { clock }
        live.apply(.offline, to: folder.id)
        #expect(live.state(folder.id).failures == 0)
        #expect(live.state(folder.id).problem == nil)
        #expect(live.state(folder.id).next == clock.addingTimeInterval(LiveSchedule.firstRetry))
    }

    // MARK: The folder's pages

    private func items(_ keys: [String]) -> [LiveItem] {
        keys.map { LiveItem(key: $0, url: URL(string: "https://example.com/\($0)")!, title: $0.uppercased(), bookmarkID: UUID()) }
    }

    @Test func keepsAtMostItsCountAndOneOfEach() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Live").id
        let folder = try #require(Library.shared.addLiveFolder(named: "Feed", source: .feed(URL(string: "https://example.com/f")!), limit: 10, namedByFeed: false, in: space))
        Library.shared.setLiveItems(items((0..<30).map { "p\($0)" } + ["p0"]), ofFolder: folder.id)
        #expect(Library.shared.allBookmarkIDs(inFolder: folder.id).count == 10)
        #expect(Library.shared.folder(folder.id)?.live?.items.map(\.key) == (0..<10).map { "p\($0)" })
        // Pages still in the feed keep their pages; a new name from the feed renames them.
        let kept = try #require(Library.shared.folder(folder.id)?.live?.items.first { $0.key == "p3" }?.bookmarkID)
        var next = items(["new"] + (1..<10).map { "p\($0)" })
        next[3].title = "Renamed"
        Library.shared.setLiveItems(next, ofFolder: folder.id)
        #expect(Library.shared.folder(folder.id)?.live?.items.first { $0.key == "p3" }?.bookmarkID == kept)
        #expect(Library.shared.bookmark(kept)?.title == "Renamed")
        #expect(titles(folder.id).first == "NEW")
        #expect(!titles(folder.id).contains("P0"))
        // Edit… to fewer: the oldest go.
        Library.shared.updateLiveFolder(folder.id, name: "Feed", namedByFeed: false, source: .feed(URL(string: "https://example.com/f")!), limit: 25)
        Library.shared.updateLiveFolder(folder.id, name: "Feed", namedByFeed: false, source: .feed(URL(string: "https://example.com/f")!), limit: 10)
        #expect(Library.shared.allBookmarkIDs(inFolder: folder.id).count == 10)
        // A new source starts over.
        Library.shared.updateLiveFolder(folder.id, name: "Other", namedByFeed: false, source: .feed(URL(string: "https://example.com/g")!), limit: 10)
        #expect(Library.shared.allBookmarkIDs(inFolder: folder.id).isEmpty)
        #expect(Library.shared.folder(folder.id)?.name == "Other")
    }

    /// Taken out, a page leaves a copy in the folder; put in, a page lands beside it instead.
    @Test func itsPagesAreItsFeedsAlone() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Live").id
        let other = Library.shared.addSpace(name: "Other").id
        let mine = try #require(Library.shared.addBookmark(url: URL(string: "https://example.org/mine")!, title: "Mine", to: space))
        let folder = try #require(Library.shared.addLiveFolder(named: "Feed", source: .feed(URL(string: "https://example.com/f")!), limit: 25, namedByFeed: false, in: space))
        Library.shared.setLiveItems(items(["a", "b", "c"]), ofFolder: folder.id)
        let pages = Library.shared.allBookmarkIDs(inFolder: folder.id)
        #expect(pages.count == 3)
        #expect(Library.shared.isLivePage(pages[0]))

        // Dragged out to the end of the pins: it stays there, and the folder has its page again.
        Library.shared.moveBookmark(pages[1], to: Int.max, in: space, folder: nil)
        #expect(Library.shared.folderID(containing: pages[1]) == nil)
        #expect(Library.shared.bookmark(pages[1])?.title == "B")
        #expect(titles(folder.id) == ["A", "B", "C"])
        #expect(!Library.shared.allBookmarkIDs(inFolder: folder.id).contains(pages[1]))
        // To another space, and to Favorites: the same.
        let third = Library.shared.allBookmarkIDs(inFolder: folder.id)[2]
        Library.shared.moveBookmark(third, to: 0, in: other)
        #expect(Library.shared.spaceID(ofBookmark: third) == other)
        let first = Library.shared.allBookmarkIDs(inFolder: folder.id)[0]
        Library.shared.makeFavorite(first, in: Library.shared.profileID(ofSpace: space))
        #expect(Library.shared.isFavorite(first))
        // Removed: back at once, as the feed has it.
        Library.shared.removeBookmark(Library.shared.allBookmarkIDs(inFolder: folder.id)[1])
        #expect(titles(folder.id) == ["A", "B", "C"])

        // Nothing goes in: not a page, not a folder.
        Library.shared.moveBookmark(mine.id, to: 1, in: space, folder: folder.id)
        #expect(Library.shared.folderID(containing: mine.id) == nil)
        Library.shared.setFolder(of: mine.id, to: folder.id)
        #expect(Library.shared.folderID(containing: mine.id) == nil)
        let inner = try #require(Library.shared.addFolder(named: "Inner", with: [], in: space, parent: folder.id))
        #expect(Library.shared.folder(inner.id)?.parentID == nil)
        #expect(titles(folder.id) == ["A", "B", "C"])
        // Side by side in the list, newest first.
        let order = Library.shared.bookmarks(in: space).map(\.id)
        let shown = Library.shared.allBookmarkIDs(inFolder: folder.id)
        let start = try #require(order.firstIndex(of: shown[0]))
        #expect(Array(order[start..<start + 3]) == shown)

        // Delete Live Folder: its pages go with it; what was taken out stays.
        Library.shared.removeFolder(folder.id)
        #expect(Library.shared.folder(folder.id) == nil)
        #expect(shown.allSatisfy { Library.shared.bookmark($0) == nil })
        #expect(Library.shared.bookmark(pages[1]) != nil)
    }

    @Test func undoPutsTheFolderBackAsItWas() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Live").id
        let folder = try #require(Library.shared.addLiveFolder(named: "Feed", source: .feed(URL(string: "https://example.com/f")!), limit: 25, namedByFeed: false, in: space))
        Library.shared.setLiveItems(items(["a", "b"]), ofFolder: folder.id)
        let kept = Library.shared.snapshot
        Library.shared.removeFolder(folder.id)
        Library.shared.restore(kept)
        #expect(titles(folder.id) == ["A", "B"])
        Library.shared.setLiveItems(items(["a", "b"]), ofFolder: folder.id)
        #expect(Library.shared.snapshot == kept)
    }

    // MARK: Saving

    /// Saved with the pins, readable by this Zigzag and an older one; the dots and fetch state in their own file.
    @Test func persistsAndReadsBack() throws {
        var folder = BookmarkFolder(name: "Feed")
        folder.live = LiveFolder(source: .feed(URL(string: "https://example.com/")!, found: URL(string: "https://example.com/feed")!),
                                 limit: 50, namedByFeed: true, items: items(["a"]))
        let space = SpaceInfo(name: "S", color: .graphite, bookmarks: [], folders: [folder])
        let data = try JSONEncoder().encode(space)
        let read = try JSONDecoder().decode(SpaceInfo.self, from: data)
        #expect(read.folders?.first?.live == folder.live)
        // Saved before live folders: a plain folder.
        let old = try JSONDecoder().decode(BookmarkFolder.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","bookmarkIDs":[],"isOpen":true}"#.utf8))
        #expect(old.live == nil)
        // A count this version doesn't offer reads as the usual one.
        let odd = try JSONDecoder().decode(LiveFolder.self, from: Data(#"{"source":{"address":"https://example.com/"},"limit":7}"#.utf8))
        #expect(odd.limit == LiveFolder.defaultLimit && odd.items.isEmpty)

        // The dots and the fetch state, written and read back by the next launch.
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let made = try #require(Library.shared.addLiveFolder(named: "Feed", source: .feed(URL(string: "https://example.com/f")!), limit: 25,
                                                             namedByFeed: false, in: Library.shared.addSpace(name: "Live").id))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LiveFolders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let live = LiveFolders(file: file, library: .shared, fetcher: Self.fetcher())
        live.apply(.entries([LiveFeed.Entry(key: "a", url: URL(string: "https://example.com/a")!, title: "A")], title: nil, feed: nil,
                            validators: .init(etag: "e", lastModified: nil)), to: made.id)
        live.apply(.failed(.notAFeed, retryAfter: nil), to: made.id)
        live.saveNow()
        let again = LiveFolders(file: file, library: .shared, fetcher: Self.fetcher())
        let saved = again.state(made.id), kept = live.state(made.id)
        #expect(saved.unread == ["a"] && saved.seen == kept.seen && saved.validators == kept.validators)
        #expect(saved.problem == .notAFeed && saved.failures == 1)
        #expect(abs((saved.next ?? .distantPast).timeIntervalSince(kept.next ?? .distantFuture)) < 0.01)
        #expect(again.unreadCount(made.id) == 1)
    }

    /// Opening a live folder's page from the sidebar takes its dot off.
    @Test func openingAPageReadsIt() throws {
        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let space = Library.shared.addSpace(name: "Live").id
        let folder = try #require(Library.shared.addLiveFolder(named: "Feed", source: .feed(URL(string: "https://example.com/f")!), limit: 25, namedByFeed: false, in: space))
        let live = LiveFolders.shared
        live.apply(.entries([LiveFeed.Entry(key: "x", url: URL(string: "https://example.com/x")!, title: "X")], title: nil, feed: nil, validators: .init()), to: folder.id)
        let page = try #require(Library.shared.allBookmarkIDs(inFolder: folder.id).first.flatMap(Library.shared.bookmark))
        #expect(live.isUnread(bookmark: page.id))
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        manager.openBookmark(page)
        #expect(!live.isUnread(bookmark: page.id))
        // A private window reads nothing.
        live.setRead(bookmark: page.id, false)
        let hidden = TabManager(spaceID: space, isPrivate: true)
        defer { hidden.invalidate() }
        hidden.openBookmark(page)
        #expect(live.isUnread(bookmark: page.id))
    }
}

import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// The History page: how its search matches, and how its list answers the keyboard and the pointer.
@MainActor
struct HistoryPageTests {
    // MARK: Search

    /// Mid-afternoon, so a few minutes back never crosses into another part of the day.
    private let base = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: Date())!

    private func entry(_ url: String, _ title: String, minutesAgo: Double = 0, count: Int = 1) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, visitCount: count, lastVisit: base.addingTimeInterval(-minutesAgo * 60))
    }

    private func found(_ query: String, in entries: [HistoryEntry]) -> [String] {
        let rows = entries.sorted { $0.lastVisit > $1.lastVisit }.map(HistorySearch.row)
        return HistorySearch.find(HistorySearch.words(query), in: rows).map(\.title)
    }

    /// Every word, in any order, in the title or the address; case, accents and full-width letters aside.
    @Test func searchMatchesEveryWordInAnyOrderInTitleOrAddress() {
        let entries = [
            entry("https://fr.wikipedia.org/wiki/Caf%C3%A9_de_Flore", "Café de Flore — Wikipédia", minutesAgo: 1),
            entry("https://github.com/zigzag/zigzag/issues/412", "History search is slow", minutesAgo: 2),
            entry("https://www.google.com/search?q=naive", "naïve - Google Search", minutesAgo: 3),
            entry("https://example.com/ＡＢＣ", "Full width", minutesAgo: 4),
        ]
        #expect(found("cafe", in: entries) == ["Café de Flore — Wikipédia"])
        #expect(found("CAFÉ", in: entries) == ["Café de Flore — Wikipédia"])
        #expect(found("wikipedia flore", in: entries) == ["Café de Flore — Wikipédia"])
        #expect(found("flore wikipedia", in: entries) == ["Café de Flore — Wikipédia"])
        // The host and the path count as the address; "www." doesn't.
        #expect(found("github 412", in: entries) == ["History search is slow"])
        #expect(found("google.com naive", in: entries) == ["naïve - Google Search"])
        #expect(found("www.google", in: entries).isEmpty)
        #expect(found("abc", in: entries) == ["Full width"])
        // Every word must be there.
        #expect(found("github flore", in: entries).isEmpty)
        #expect(found("   ", in: entries).isEmpty)
    }

    /// Chinese is found in titles and in addresses, which are read decoded; an ideographic space splits words too.
    @Test func searchFindsChineseInTitlesAndAddresses() {
        let entries = [
            entry("https://zh.wikipedia.org/wiki/%E5%A4%96%E6%BB%A9", "Bund", minutesAgo: 1),
            entry("https://www.zhihu.com/question/1", "上海 天气 怎么样", minutesAgo: 2),
            entry("https://www.baidu.com/s?wd=%E4%B8%8A%E6%B5%B7", "百度一下", minutesAgo: 3),
        ]
        #expect(found("外滩", in: entries) == ["Bund"])
        #expect(found("上海", in: entries) == ["上海 天气 怎么样", "百度一下"])
        #expect(found("天气\u{3000}上海", in: entries) == ["上海 天气 怎么样"])
        #expect(found("知乎", in: entries).isEmpty)
    }

    /// Matches come newest first, as History lists them, and a visit counted often doesn't jump the line.
    @Test func searchListsMatchesNewestFirst() {
        let entries = [
            entry("https://a.com/old", "Swift old", minutesAgo: 600, count: 50),
            entry("https://a.com/new", "Swift new", minutesAgo: 1),
            entry("https://a.com/mid", "Swift mid", minutesAgo: 60, count: 5),
        ]
        #expect(found("swift", in: entries) == ["Swift new", "Swift mid", "Swift old"])
        let many = (0..<1500).map { entry("https://a.com/\($0)", "Swift \($0)", minutesAgo: Double($0)) }
        #expect(found("swift", in: many).count == HistorySearch.limit)
        #expect(found("swift", in: many).first == "Swift 0")
    }

    /// Fifty thousand pages: the first search reads and folds them all, and each letter after that only looks.
    @Test func searchOverFiftyThousandPagesStaysQuick() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(path: folder.appendingPathComponent("History.sqlite").path)
        let titles = ["Swift release notes", "上海 天气 预报", "Café guide", "Kitchen garden recipe", "Python docs api"]
        let now = Date()
        store.importVisits((0..<50_000).map { i in
            (URL(string: "https://site\(i % 3000).example.com/p/\(i)")!, titles[i % titles.count] + " \(i)", 1 + i % 7, now.addingTimeInterval(-Double(i) * 30))
        })
        let cold = Date()
        let first = await store.pageSearch("swift notes", asker: 1) { $0.count }
        let coldTime = Date().timeIntervalSince(cold)
        #expect(first == HistorySearch.limit)
        var warmTimes: [TimeInterval] = []
        for query in ["cafe", "上海 天气", "kitchen 4999", "zzz nothing"] {
            let start = Date()
            _ = await store.pageSearch(query, asker: 1) { $0.count }
            warmTimes.append(Date().timeIntervalSince(start))
        }
        #expect(await store.pageSearch("kitchen 49998", asker: 1) { $0.map(\.title) } == ["Kitchen garden recipe 49998"])
        #expect(coldTime < 3, "first search took \(coldTime) s")
        #expect(warmTimes.max()! < 0.25, "searches took \(warmTimes) s")
        // A page recorded since is found: the folded copy is read again once the file changes.
        store.recordVisit(url: URL(string: "https://new.example.com/")!, title: "Brand new zebra", at: Date())
        #expect(await store.pageSearch("zebra", asker: 1) { $0.count } == 1)
    }

    /// Removing a site takes all its pages, "www." or not, and ⌘Z's restore brings them back.
    @Test func removingASiteTakesAllItsPagesAndComesBack() {
        let store = HistoryStore(path: ":memory:")
        store.recordVisit(url: URL(string: "https://www.github.com/a")!, title: "A")
        store.recordVisit(url: URL(string: "https://github.com/b")!, title: "B")
        store.recordVisit(url: URL(string: "https://gist.github.com/c")!, title: "C")
        let removal = store.remove(host: "github.com")
        #expect(Set(removal.visits.map(\.title)) == ["A", "B"])
        #expect(store.recent().map(\.title) == ["C"])
        store.restore(removal)
        #expect(store.recent().count == 3)
    }

    /// History, the Archive and Settings are light or dark with the window, as Settings' own views are: never darkened
    /// as a web page, never set to the Mac's look alone. A Markdown file stays a document.
    @Test func ownPagesFollowTheWindow() {
        for url in [HistoryPage.url, ArchivePage.url, SettingsPage.url, SettingsPage.url(for: .privacy)] {
            #expect(HistoryPage.followsWindow(url), "\(url)")
            #expect(!DarkPages.applies(to: url), "\(url)")
        }
        let markdown = URL(string: "\(HistoryPage.scheme)://\(MarkdownPage.host)/notes.md")!
        #expect(!HistoryPage.followsWindow(markdown))
        #expect(DarkPages.applies(to: markdown))
        #expect(!HistoryPage.followsWindow(URL(string: "https://history.example.com/")))
    }

    // MARK: The page

    /// Stands in for the browser: serves `entries` and keeps what the page asked for.
    private final class Browser: NSObject, WKScriptMessageHandlerWithReply {
        var entries: [HistoryEntry] = []
        var asked: [[String: Any]] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { replyHandler(nil, "?"); return }
            asked.append(body)
            switch action {
            case "page":
                replyHandler(body["before"] is NSNull || body["before"] == nil ? HistoryPage.sessions(entries) : [], nil)
            case "search":
                let rows = entries.sorted { $0.lastVisit > $1.lastVisit }.map(HistorySearch.row)
                let found = HistorySearch.find(HistorySearch.words(body["query"] as? String ?? ""), in: rows)
                let json = try? JSONSerialization.data(withJSONObject: HistoryPage.sessions(found, stacks: false))
                replyHandler(json.flatMap { String(data: $0, encoding: .utf8) } ?? "[]", nil)
            case "delete":
                let gone = Set((body["urls"] as? [String]) ?? [])
                entries.removeAll { gone.contains($0.url.absoluteString) }
                replyHandler(true, nil)
            default:
                replyHandler(true, nil)
            }
        }

        func asked(_ action: String) -> [[String: Any]] { asked.filter { $0["action"] as? String == action } }
    }

    /// Two github.com pages, a stack of three on example.com, and one on news.com, a minute apart.
    private func load() async throws -> (WKWebView, NSWindow, Browser) {
        let browser = Browser()
        browser.entries = [
            entry("https://github.com/a", "GitHub A", minutesAgo: 1),
            entry("https://github.com/b", "GitHub B", minutesAgo: 2),
            entry("https://example.com/1", "Example 1", minutesAgo: 3),
            entry("https://example.com/2", "Example 2", minutesAgo: 4),
            entry("https://example.com/3", "Example 3", minutesAgo: 5),
            entry("https://news.com/", "Café news", minutesAgo: 6),
        ]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(browser, contentWorld: .page, name: "zigzagHistory")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 800), configuration: configuration)
        window.contentView = webView
        webView.loadHTMLString(HistoryPage.html(for: webView), baseURL: nil)
        for _ in 0..<100 where try await rows(webView).count < 5 { try await Task.sleep(for: .milliseconds(50)) }
        return (webView, window, browser)
    }

    private func run(_ webView: WKWebView, _ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    /// The rows as drawn, each "title" with a "*" when chosen.
    private func rows(_ webView: WKWebView) async throws -> [String] {
        try await run(webView, "return [...document.querySelectorAll('#list .row')].map((r) => r.querySelector('.title').textContent + (r.classList.contains('selected') ? '*' : ''))") as? [String] ?? []
    }

    private func press(_ webView: WKWebView, _ key: String, shift: Bool = false, meta: Bool = false) async throws {
        _ = try await run(webView, """
            const target = document.activeElement || document.body;
            target.dispatchEvent(new KeyboardEvent('keydown', { key: \(Self.quoted(key)), shiftKey: \(shift), metaKey: \(meta), bubbles: true, cancelable: true }));
            await new Promise((r) => setTimeout(r, 30));
            """)
    }

    private static func quoted(_ s: String) -> String { "'" + s + "'" }

    /// The stack of three folds; the two GitHub pages, too few to stack, are rows.
    @Test func runsOfTwoAreRowsAndThreeStack() async throws {
        let (webView, window, _) = try await load()
        #expect(try await rows(webView) == ["GitHub A", "GitHub B", "example.com", "Café news"])
        withExtendedLifetime(window) {}
    }

    /// ↓ from the search field chooses the first row, ↓ and ⇧↓ walk and extend, → opens a stack and ← closes it,
    /// Esc lets go, ↑ from the top goes back to the search field.
    @Test func arrowsChooseExtendAndOpenStacks() async throws {
        let (webView, window, _) = try await load()
        try await press(webView, "ArrowDown")
        #expect(try await rows(webView) == ["GitHub A*", "GitHub B", "example.com", "Café news"])
        try await press(webView, "ArrowDown", shift: true)
        try await press(webView, "ArrowDown", shift: true)
        #expect(try await rows(webView) == ["GitHub A*", "GitHub B*", "example.com*", "Café news"])
        try await press(webView, "ArrowRight")
        #expect(try await rows(webView) == ["GitHub A", "GitHub B", "example.com*", "Example 1", "Example 2", "Example 3", "Café news"])
        try await press(webView, "ArrowRight")
        try await press(webView, "ArrowDown")
        #expect(try await rows(webView) == ["GitHub A", "GitHub B", "example.com", "Example 1", "Example 2*", "Example 3", "Café news"])
        try await press(webView, "ArrowLeft")
        try await press(webView, "ArrowLeft")
        #expect(try await rows(webView) == ["GitHub A", "GitHub B", "example.com*", "Café news"])
        try await press(webView, "Escape")
        #expect(try await rows(webView) == ["GitHub A", "GitHub B", "example.com", "Café news"])
        try await press(webView, "ArrowUp")
        try await press(webView, "ArrowUp")
        try await press(webView, "ArrowUp")
        try await press(webView, "ArrowUp")
        #expect(try await run(webView, "return document.activeElement.id") as? String == "query")
        withExtendedLifetime(window) {}
    }

    /// Delete removes what's chosen (a stack: all its pages) and chooses the row after; ⌘Return opens the chosen
    /// pages in tabs behind; typing on a row goes to the search field.
    @Test func deleteRemovesTheChosenAndCommandReturnOpensThem() async throws {
        let (webView, window, browser) = try await load()
        try await press(webView, "ArrowDown")
        try await press(webView, "ArrowDown")
        try await press(webView, "ArrowDown")
        try await press(webView, "Enter", meta: true)
        #expect(browser.asked("open").last?["urls"] as? [String] == ["https://example.com/1", "https://example.com/2", "https://example.com/3"])
        try await press(webView, "Backspace")
        #expect(browser.asked("delete").last?["urls"] as? [String] == ["https://example.com/1", "https://example.com/2", "https://example.com/3"])
        #expect(try await rows(webView) == ["GitHub A", "GitHub B", "Café news*"])
        try await press(webView, "ArrowUp", shift: true)
        try await press(webView, "Delete")
        #expect(browser.asked("delete").last?["urls"] as? [String] == ["https://github.com/b", "https://news.com/"])
        #expect(try await rows(webView) == ["GitHub A*"])
        try await press(webView, "g")
        #expect(try await run(webView, "return document.activeElement.id + ' ' + document.getElementById('query').value") as? String == "query g")
        withExtendedLifetime(window) {}
    }

    /// A search shows every match as its own row, never folded in a stack, with what was typed marked and the first
    /// match chosen for Return.
    @Test func searchNeverHidesAMatchInAStack() async throws {
        let (webView, window, _) = try await load()
        _ = try await run(webView, "document.getElementById('query').value = 'example'; await search();")
        #expect(try await rows(webView) == ["Example 1*", "Example 2", "Example 3"])
        #expect(try await run(webView, "return document.querySelectorAll('.cluster').length") as? Int == 0)
        _ = try await run(webView, "document.getElementById('query').value = 'CAFE'; await search();")
        #expect(try await rows(webView) == ["Café news*"])
        #expect(try await run(webView, "return [...document.querySelectorAll('#list .title mark')].map((m) => m.textContent)") as? [String] == ["Café"])
        _ = try await run(webView, "document.getElementById('query').value = 'nothing here'; await search();")
        #expect(try await rows(webView) == [])
        #expect(try await run(webView, "return document.getElementById('empty').hidden") as? Bool == false)
        withExtendedLifetime(window) {}
    }
}

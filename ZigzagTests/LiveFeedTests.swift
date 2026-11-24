import Foundation
import Testing
@testable import Zigzag

/// Reading feeds for live folders: RSS, Atom and RDF, the mistakes real feeds make, their dates, finding a site's
/// feed from its page, and GitHub's lists.
struct LiveFeedTests {
    private let base = URL(string: "https://example.com/blog/feed.xml")!

    private func parse(_ xml: String) -> LiveFeed? { LiveFeedParser.parse(Data(xml.utf8), base: base) }

    @Test func readsAnRSSFeedNewestFirst() throws {
        let feed = try #require(parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Example &amp; Co</title><link>https://example.com/</link>
          <item><title>Older</title><link>https://example.com/older</link><guid>a1</guid><pubDate>Mon, 02 Nov 2026 09:00:00 GMT</pubDate></item>
          <item><title><![CDATA[Newer <b>post</b>]]></title><link>https://example.com/newer</link><guid>a2</guid><pubDate>Tue, 03 Nov 2026 09:00:00 +0000</pubDate></item>
        </channel></rss>
        """))
        #expect(feed.title == "Example & Co")
        #expect(feed.entries.map(\.title) == ["Newer post", "Older"])
        #expect(feed.entries.map(\.key) == ["a2", "a1"])
        #expect(feed.entries.first?.url == URL(string: "https://example.com/newer"))
    }

    @Test func readsAnAtomFeedWithItsBaseAndHTMLTitles() throws {
        let feed = try #require(parse("""
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://example.org/journal/">
          <title type="text">Journal</title>
          <link rel="self" href="https://example.org/journal/atom.xml"/>
          <entry><id>tag:example.org,2026:1</id><title type="html">Caf&amp;eacute; &amp;amp; more</title>
            <link rel="alternate" type="text/html" href="2026/cafe"/><link rel="replies" href="2026/cafe#comments"/>
            <updated>2026-11-20T10:00:00Z</updated></entry>
          <entry><id>tag:example.org,2026:2</id><title>Second</title><link href="/top"/>
            <published>2026-11-21T10:00:00.123+01:00</published><updated>2026-11-01T10:00:00Z</updated></entry>
        </feed>
        """))
        #expect(feed.title == "Journal")
        #expect(feed.entries.map(\.title) == ["Second", "Café & more"])
        #expect(feed.entries.map(\.url.absoluteString) == ["https://example.org/top", "https://example.org/journal/2026/cafe"])
        #expect(feed.entries.map(\.key) == ["tag:example.org,2026:2", "tag:example.org,2026:1"])
    }

    @Test func readsAnRDFFeed() throws {
        let feed = try #require(parse("""
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel rdf:about="https://example.net/"><title>Net</title></channel>
          <item rdf:about="https://example.net/one"><title>One</title><link>https://example.net/one</link><dc:date>2026-11-02</dc:date></item>
          <item rdf:about="https://example.net/two"><title>Two</title><link>https://example.net/two</link><dc:date>2026-11-03</dc:date></item>
        </rdf:RDF>
        """))
        #expect(feed.title == "Net")
        #expect(feed.entries.map(\.title) == ["Two", "One"])
        #expect(feed.entries.first?.key == "https://example.net/two")
    }

    /// Relative links resolve against the feed's own address; links that aren't web pages are left out.
    @Test func resolvesRelativeLinksAndSkipsOthers() throws {
        let feed = try #require(parse("""
        <rss><channel><title>T</title>
          <item><title>Relative</title><link>../posts/1</link></item>
          <item><title>Rooted</title><link>/posts/2</link></item>
          <item><title>Script</title><link>javascript:alert(1)</link></item>
          <item><title>Nothing</title></item>
          <item><title>Guid only</title><guid>https://example.com/posts/3</guid></item>
          <item><title>Not a link</title><guid isPermaLink="false">xyz</guid></item>
        </channel></rss>
        """))
        #expect(feed.entries.map(\.url.absoluteString) == ["https://example.com/posts/1", "https://example.com/posts/2", "https://example.com/posts/3"])
    }

    /// HTML's entities XML doesn't know, and a bare &, as hand-written feeds have them.
    @Test func readsAFeedWithHTMLEntitiesAndBareAmpersands() throws {
        let feed = try #require(parse("""
        <rss><channel><title>Tom&nbsp;&amp;&nbsp;Jerry</title>
          <item><title>Rock & roll &mdash; live &hellip; &#8220;quoted&#x201D;</title><link>https://example.com/a?b=1&c=2</link></item>
        </channel></rss>
        """))
        #expect(feed.title == "Tom & Jerry")
        #expect(feed.entries.first?.title == "Rock & roll — live … “quoted”")
        #expect(feed.entries.first?.url.absoluteString == "https://example.com/a?b=1&c=2")
        // Double escaped, as many feeds write them.
        #expect(FeedText.title("Ben &amp;amp; Jerry&#39;s") == "Ben &amp; Jerry's")
        #expect(FeedText.title("&lt;b&gt;Bold&lt;/b&gt; move") == "<b>Bold</b> move")
    }

    @Test func refusesWhatIsntAFeed() {
        #expect(parse("<html><head><title>Page</title></head><body>Hi</body></html>") == nil)
        #expect(parse("not xml at all") == nil)
        #expect(parse("") == nil)
        #expect(parse("<rss><channel><item><title>Cut off") == nil)
    }

    /// One entry per guid, the first kept; undated feeds keep their own order.
    @Test func keepsOneOfEachAndTheFeedsOrderWithoutDates() throws {
        let feed = try #require(parse("""
        <rss><channel><title>T</title>
          <item><title>B</title><link>https://example.com/b</link><guid>same</guid></item>
          <item><title>A</title><link>https://example.com/a</link></item>
          <item><title>B again</title><link>https://example.com/b2</link><guid>same</guid></item>
          <item><title>C</title><link>https://example.com/c</link><pubDate>garbage</pubDate></item>
        </channel></rss>
        """))
        #expect(feed.entries.map(\.title) == ["B", "A", "C"])
        #expect(feed.entries.allSatisfy { $0.date == nil })
    }

    @Test func titlesAreOneShortLineAndNeverEmpty() throws {
        let long = String(repeating: "word ", count: 200)
        let feed = try #require(parse("""
        <rss><channel><title>T</title>
          <item><title>  Many
             lines\there  </title><link>https://example.com/1</link></item>
          <item><title>\(long)</title><link>https://example.com/2</link></item>
          <item><title></title><link>https://www.example.com/untitled/post</link></item>
        </channel></rss>
        """))
        #expect(feed.entries[0].title == "Many lines here")
        #expect(feed.entries[1].title.count == FeedText.maxTitle + 1)
        #expect(feed.entries[2].title == "example.com/untitled/post")
    }

    @Test func readsAtMostSoManyEntries() throws {
        let items = (0..<(LiveFeedParser.maxEntries + 40)).map { "<item><title>\($0)</title><link>https://example.com/\($0)</link></item>" }.joined()
        let feed = try #require(parse("<rss><channel><title>T</title>\(items)</channel></rss>"))
        #expect(feed.entries.count == LiveFeedParser.maxEntries)
    }

    @Test func readsTheDatesFeedsWrite() {
        let day = Date(timeIntervalSince1970: 1_793_609_200) // 2026-11-02 08:46:40 UTC
        #expect(FeedDates.parse("Mon, 02 Nov 2026 08:46:40 GMT") == day)
        #expect(FeedDates.parse("Mon, 2 Nov 2026 08:46:40 +0000") == day)
        #expect(FeedDates.parse("Mon, 02 Nov 2026 03:46:40 EST") == day)
        #expect(FeedDates.parse("Mon, 02 Nov 2026 08:46:40 UT") == day)
        #expect(FeedDates.parse("02 Nov 2026 08:46:40 +0000") == day)
        #expect(FeedDates.parse("2026-11-02T08:46:40Z") == day)
        #expect(FeedDates.parse("2026-11-02T09:46:40+01:00") == day)
        #expect(FeedDates.parse("2026-11-02T08:46:40.000Z") == day)
        #expect(FeedDates.parse("2026-11-02T08:46:40") == day)
        #expect(FeedDates.parse("2026-11-02") == Date(timeIntervalSince1970: 1_793_577_600))
        #expect(FeedDates.parse("yesterday") == nil)
        #expect(FeedDates.parse("") == nil)
    }

    @Test func findsASitesFeedsFromItsPage() {
        let page = URL(string: "https://example.com/blog/post")!
        let html = """
        <html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="Comments Feed" href="/comments/feed/">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='atom.xml?a=1&amp;b=2'>
        <link type="application/rss+xml" rel="alternate home" href="https://feeds.example.com/main">
        <link rel="alternate" type="text/html" href="/other">
        </head><body></body></html>
        """
        #expect(FeedDiscovery.feeds(inHTML: html, base: page).map(\.absoluteString)
                == ["https://example.com/blog/atom.xml?a=1&b=2", "https://feeds.example.com/main", "https://example.com/comments/feed/"])
        // A <base> moves where relative links point.
        let based = "<head><base href=\"https://cdn.example.com/site/\"><link rel=alternate type=application/rss+xml href=rss></head>"
        #expect(FeedDiscovery.feeds(inHTML: based, base: page) == [URL(string: "https://cdn.example.com/site/rss")!])
        #expect(FeedDiscovery.feeds(inHTML: "<html><head></head></html>", base: page).isEmpty)
        #expect(FeedDiscovery.looksLikeFeed(Data("<?xml version='1.0'?><rss>".utf8)))
        #expect(!FeedDiscovery.looksLikeFeed(Data("<!doctype html><html>".utf8)))
    }

    @Test func asksGitHubForTheListsOfAUser() throws {
        func query(_ list: GitHubList) throws -> String {
            let parts = try #require(URLComponents(url: list.url(for: "octocat", count: 25), resolvingAgainstBaseURL: false))
            #expect(parts.host == "api.github.com")
            #expect(parts.queryItems?.first { $0.name == "per_page" }?.value == "25")
            #expect(parts.queryItems?.first { $0.name == "sort" }?.value == "updated")
            return try #require(parts.queryItems?.first { $0.name == "q" }?.value)
        }
        #expect(try query(.pullRequests) == "is:pr is:open archived:false author:octocat")
        #expect(try query(.issues) == "is:issue is:open archived:false assignee:octocat")
        #expect(try query(.reviewRequests) == "is:pr is:open archived:false review-requested:octocat")
        #expect(GitHubList.isUsername("octo-cat9"))
        #expect(!GitHubList.isUsername("-octo"))
        #expect(!GitHubList.isUsername("oc--to"))
        #expect(!GitHubList.isUsername("octo cat"))
        #expect(!GitHubList.isUsername(String(repeating: "a", count: 40)))
    }

    @Test func readsGitHubsSearchAnswer() throws {
        let json = """
        {"total_count": 2, "items": [
          {"html_url": "https://github.com/a/b/pull/2", "title": "Older &amp; fine", "updated_at": "2026-11-01T00:00:00Z"},
          {"html_url": "https://github.com/a/b/pull/3", "title": "Newer", "updated_at": "2026-11-02T00:00:00Z"}
        ]}
        """
        let entries = try #require(GitHubList.entries(Data(json.utf8)))
        #expect(entries.map(\.title) == ["Newer", "Older & fine"])
        #expect(entries.map(\.key) == ["https://github.com/a/b/pull/3", "https://github.com/a/b/pull/2"])
        #expect(GitHubList.entries(Data("{\"message\": \"Bad credentials\"}".utf8)) == nil)
    }

    @Test func typedAddressesBecomeWebAddresses() {
        #expect(LiveFolderSheet.address(from: " example.com/feed ") == URL(string: "https://example.com/feed"))
        #expect(LiveFolderSheet.address(from: "http://example.com") == URL(string: "http://example.com"))
        #expect(LiveFolderSheet.address(from: "feed://example.com/rss") == URL(string: "https://example.com/rss"))
        #expect(LiveFolderSheet.address(from: "feed:https://example.com/rss") == URL(string: "https://example.com/rss"))
        #expect(LiveFolderSheet.address(from: "localhost:4000/feed.xml") != nil)
        #expect(LiveFolderSheet.address(from: "not a url") == nil)
        #expect(LiveFolderSheet.address(from: "word") == nil)
        #expect(LiveFolderSheet.address(from: "file:///etc/passwd") == nil)
        #expect(LiveFolderSheet.address(from: "") == nil)
    }
}

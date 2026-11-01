import Foundation
import Testing
@testable import Zigzag

/// The address bar filling in a site you've been to: what it completes to, and when it holds back.
@MainActor
struct InlineCompletionTests {
    private func site(_ address: String, _ score: Double = 1) -> InlineCompletion.Site {
        InlineCompletion.Site(url: URL(string: address)!, score: score)
    }

    @Test func completesTheStartOfAHost() {
        let sites = [site("https://wikipedia.org"), site("https://github.com")]
        #expect(InlineCompletion.best(for: "wiki", among: sites)?.text == "wikipedia.org")
        #expect(InlineCompletion.best(for: "wiki", among: sites)?.url.absoluteString == "https://wikipedia.org")
        #expect(InlineCompletion.best(for: "WiKi", among: sites)?.text == "wikipedia.org")
        #expect(InlineCompletion.best(for: "wikipedia.org", among: sites)?.text == "wikipedia.org")
    }

    @Test func onlyTheHostsBeginningCounts() {
        // Inside a label, or in the path, is not a beginning.
        #expect(InlineCompletion.best(for: "pedia", among: [site("https://en.wikipedia.org")]) == nil)
        #expect(InlineCompletion.best(for: "wiki", among: [site("https://example.com/wiki")]) == nil)
        #expect(InlineCompletion.best(for: "en.wi", among: [site("https://en.wikipedia.org")])?.text == "en.wikipedia.org")
        // A public suffix is never a site of its own.
        #expect(InlineCompletion.best(for: "co", among: [site("https://news.bbc.co.uk")]) == nil)
        #expect(InlineCompletion.best(for: "local", among: [site("http://printer.local")]) == nil)
    }

    @Test func aSubdomainDropsAway() {
        let wiki = InlineCompletion.best(for: "wiki", among: [site("https://en.wikipedia.org/wiki/Swift")])
        #expect(wiki?.text == "wikipedia.org")
        #expect(wiki?.url.absoluteString == "https://wikipedia.org")
        #expect(InlineCompletion.best(for: "you", among: [site("https://m.youtube.com")])?.text == "youtube.com")
        #expect(InlineCompletion.best(for: "goo", among: [site("https://docs.google.com")])?.text == "google.com")
        #expect(InlineCompletion.best(for: "bb", among: [site("https://news.bbc.co.uk")])?.text == "bbc.co.uk")
        #expect(InlineCompletion.best(for: "dev", among: [site("https://a.dev.example.com")])?.text == "dev.example.com")
        #expect(InlineCompletion.shortenedHosts("a.b.example.co.uk") == ["b.example.co.uk", "example.co.uk"])
        #expect(InlineCompletion.shortenedHosts("example.com").isEmpty)
        #expect(InlineCompletion.shortenedHosts("192.168.1.1").isEmpty)
    }

    @Test func aWholeHostBeatsAShortenedOne() {
        // en.wikipedia.org is used far more, but wikihow.com starts with what you typed as it is.
        let sites = [site("https://en.wikipedia.org", 50), site("https://www.wikihow.com", 1)]
        #expect(InlineCompletion.best(for: "wiki", among: sites)?.text == "wikihow.com")
        #expect(InlineCompletion.best(for: "wikip", among: sites)?.text == "wikipedia.org")
        // Two that both only match shortened: the more used.
        let both = [site("https://de.wikipedia.org", 2), site("https://en.wikipedia.org", 7)]
        #expect(InlineCompletion.best(for: "wiki", among: both)?.text == "wikipedia.org")
    }

    @Test func matchesWithAndWithoutWWW() {
        let sites = [site("https://www.wikipedia.org")]
        #expect(InlineCompletion.best(for: "wiki", among: sites)?.text == "wikipedia.org")
        #expect(InlineCompletion.best(for: "www.wiki", among: sites)?.text == "www.wikipedia.org")
        // The address keeps the "www." it was visited with, so the site answers as it did.
        #expect(InlineCompletion.best(for: "wiki", among: sites)?.url.host() == "www.wikipedia.org")
        #expect(InlineCompletion.best(for: "www.", among: sites) == nil)
    }

    @Test func theMostUsedSiteWins() {
        let sites = [site("https://github.com", 2), site("https://gitlab.com", 9), site("https://gist.github.com", 9)]
        #expect(InlineCompletion.best(for: "gi", among: sites)?.text == "gitlab.com")
        #expect(InlineCompletion.best(for: "github", among: sites)?.text == "github.com")
        // Even: the shorter address.
        #expect(InlineCompletion.best(for: "gi", among: [site("https://gist.github.com"), site("https://github.com")])?.text == "github.com")
    }

    @Test func aWholeHostYouVisitedStaysAsTyped() {
        let pages = [site("https://github.com/notifications", 9)]
        #expect(InlineCompletion.best(for: "github.co", among: pages)?.text == "github.com/notifications")
        #expect(InlineCompletion.best(for: "github.com", among: pages)?.text == "github.com")
        #expect(InlineCompletion.best(for: "github.com", among: pages)?.url.absoluteString == "https://github.com")
        let routers = [site("http://192.168.1.10", 9), site("http://192.168.1.1", 1)]
        #expect(InlineCompletion.best(for: "192.168.1.1", among: routers)?.text == "192.168.1.1")
        #expect(InlineCompletion.best(for: "192.168.1.1", among: routers)?.url.absoluteString == "http://192.168.1.1")
        // Only one you've been to: an address you haven't still completes.
        #expect(InlineCompletion.best(for: "192.168.1.1", among: [site("http://192.168.1.10")])?.text == "192.168.1.10")
        // The letter that finishes the host drops the longer completion still showing.
        let showing = InlineCompletion.Match(text: "github.com/notifications", url: URL(string: "https://github.com/notifications")!)
        let whole = InlineCompletion.Match(text: "github.com", url: URL(string: "https://github.com")!)
        #expect(InlineCompletion.next(previous: showing, found: whole, typed: "github.com") == whole)
        #expect(InlineCompletion.next(previous: showing, found: whole, typed: "github.c") == showing)
    }

    @Test func aPortAndAPathComeAlong() {
        #expect(InlineCompletion.best(for: "local", among: [site("http://localhost:3000")])?.text == "localhost:3000")
        #expect(InlineCompletion.best(for: "localhost:3", among: [site("http://localhost:3000")])?.text == "localhost:3000")
        #expect(InlineCompletion.best(for: "git", among: [site("https://github.com/zigzag/app/")])?.text == "github.com/zigzag/app")
        #expect(InlineCompletion.best(for: "github.com/", among: [site("https://github.com/zigzag/app")]) == nil)
    }

    @Test func aPageOnlyWhenItsTheOneYouVisit() {
        let page = URL(string: "https://github.com/zigzag/app")!
        #expect(InlineCompletion.target(page, wholePage: true)?.absoluteString == "https://github.com/zigzag/app")
        #expect(InlineCompletion.target(page, wholePage: false)?.absoluteString == "https://github.com")
        // A search or a place in a page only gives its site.
        #expect(InlineCompletion.target(URL(string: "https://www.google.com/search?q=cats")!, wholePage: true)?.absoluteString == "https://www.google.com")
        #expect(InlineCompletion.target(URL(string: "https://example.com/doc#part")!, wholePage: true)?.absoluteString == "https://example.com")
        #expect(InlineCompletion.target(URL(string: "file:///Users/me/page.html")!, wholePage: true) == nil)
    }

    @Test func searchesAreLeftAlone() {
        #expect(InlineCompletion.looksLikeHost("wiki"))
        #expect(InlineCompletion.looksLikeHost("localhost:30"))
        #expect(!InlineCompletion.looksLikeHost("wiki pedia"))
        #expect(!InlineCompletion.looksLikeHost("how to"))
        #expect(!InlineCompletion.looksLikeHost("github.com/zig"))
        #expect(!InlineCompletion.looksLikeHost("?wiki"))
        #expect(!InlineCompletion.looksLikeHost("c++"))
        #expect(!InlineCompletion.looksLikeHost(""))
        #expect(InlineCompletion.best(for: "wiki pedia", among: [site("https://wikipedia.org")]) == nil)
    }

    @Test func typingForwardCompletes() {
        #expect(InlineCompletion.allowed("w", shown: "", typed: "", deleting: false, caretAtEnd: true, hasMarkedText: false))
        // A letter that replaces the selected completion.
        #expect(InlineCompletion.allowed("wikip", shown: "wikipedia.org", typed: "wiki", deleting: false, caretAtEnd: true, hasMarkedText: false))
        // A new address over the whole old one.
        #expect(InlineCompletion.allowed("g", shown: "https://example.com/", typed: "https://example.com/", deleting: false, caretAtEnd: true, hasMarkedText: false))
    }

    @Test func deletingNeverCompletes() {
        // A cut of the selected completion leaves exactly what you typed.
        #expect(!InlineCompletion.allowed("wiki", shown: "wikipedia.org", typed: "wiki", deleting: false, caretAtEnd: true, hasMarkedText: false))
        // Backspace on a letter of what you typed.
        #expect(!InlineCompletion.allowed("wik", shown: "wiki", typed: "wiki", deleting: true, caretAtEnd: true, hasMarkedText: false))
        #expect(InlineCompletion.isDeletion("", shown: "w", typed: "w", deleting: true))
        #expect(!InlineCompletion.isDeletion("wikix", shown: "wikipedia.org", typed: "wiki", deleting: false))
    }

    @Test func aFirstLetterOverTheWholeAddressCompletes() {
        // ⌘L selects the address; "h" replaces it, and is a beginning of it, but nothing was deleted.
        #expect(InlineCompletion.allowed("h", shown: "https://example.com/", typed: "https://example.com/", deleting: false,
                                         caretAtEnd: true, hasMarkedText: false))
        #expect(!InlineCompletion.isDeletion("w", shown: "wiki", typed: "wiki", deleting: false))
    }

    @Test func holdsBackMidTextWithSpacesAndWhileComposing() {
        #expect(!InlineCompletion.allowed("wiki", shown: "wik", typed: "wik", deleting: false, caretAtEnd: false, hasMarkedText: false))
        #expect(!InlineCompletion.allowed("wiki p", shown: "wiki ", typed: "wiki ", deleting: false, caretAtEnd: true, hasMarkedText: false))
        // An input method still composing (pinyin, kana): its text isn't settled, so nothing is filled in after it.
        #expect(!InlineCompletion.allowed("wiki", shown: "wik", typed: "wik", deleting: false, caretAtEnd: true, hasMarkedText: true))
    }

    @Test func aMatchingLetterKeepsTheCompletion() {
        let match = InlineCompletion.Match(text: "wikipedia.org", url: URL(string: "https://wikipedia.org")!)
        #expect(InlineCompletion.kept(match, typed: "wikip") == match)
        #expect(InlineCompletion.kept(match, typed: "WIKIP") == match)
        #expect(InlineCompletion.kept(match, typed: "wikipedia.org") == match)
        #expect(InlineCompletion.kept(match, typed: "wikix") == nil)
    }

    @Test func oneSitePerHost() {
        let merged = InlineCompletion.merge([site("https://github.com/zigzag/app", 3), site("https://github.com", 1), site("https://www.github.com", 1),
                                             site("https://gitlab.com", 2)])
        #expect(merged.count == 2)
        #expect(merged.first?.url.absoluteString == "https://github.com/zigzag/app")
        #expect(merged.first?.score == 5)
    }

    /// History of its own, in memory: never the history you browse with.
    @Test func historyGivesEachSitesMostVisitedPage() {
        let store = HistoryStore(path: ":memory:")
        let now = Date()
        store.recordVisit(url: URL(string: "https://www.wikipedia.org/")!, title: "Wikipedia", at: now, count: 2)
        store.recordVisit(url: URL(string: "https://wikipedia.org/wiki/Swift")!, title: "Swift", at: now, count: 1)
        store.recordVisit(url: URL(string: "https://github.com/zigzag/app")!, title: "Zigzag", at: now, count: 9)
        store.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub", at: now, count: 3)
        store.recordVisit(url: URL(string: "https://gist.github.com/")!, title: "Gist", at: now.addingTimeInterval(-86400 * 70), count: 9)

        let wiki = store.completionSites(for: "wiki")
        #expect(wiki.count == 1)
        #expect(wiki.first?.entry.url.absoluteString == "https://www.wikipedia.org/")
        #expect(store.completionSites(for: "WIKI").count == 1)
        #expect(store.completionSites(for: "pedia").isEmpty)

        // github.com: more visits, and lately; its most visited page is a project, so that's where it goes.
        let git = store.completionSites(for: "gi")
        #expect(git.map { HistoryStore.normalizedHost($0.entry.url) } == ["github.com", "gist.github.com"])
        #expect(git.first?.entry.url.absoluteString == "https://github.com/zigzag/app")
        let sites = git.compactMap { entry, score in InlineCompletion.target(entry.url, wholePage: true).map { InlineCompletion.Site(url: $0, score: score) } }
        #expect(InlineCompletion.best(for: "gi", among: sites)?.text == "github.com/zigzag/app")
    }

    @Test func historyKeepsPortsApart() {
        let store = HistoryStore(path: ":memory:")
        store.recordVisit(url: URL(string: "http://localhost:3000/app")!, title: "App", at: Date(), count: 5)
        store.recordVisit(url: URL(string: "http://localhost:8080/")!, title: "Server", at: Date(), count: 2)
        store.recordVisit(url: URL(string: "http://localhost:8080/admin")!, title: "Admin", at: Date(), count: 1)
        let found = store.completionSites(for: "local")
        #expect(found.map(\.entry.url.absoluteString) == ["http://localhost:3000/app", "http://localhost:8080/"])
        #expect(found.last?.score ?? 0 > 2.9)
    }

    @Test func historyFindsASiteBehindItsSubdomain() {
        let store = HistoryStore(path: ":memory:")
        store.recordVisit(url: URL(string: "https://en.wikipedia.org/wiki/Swift")!, title: "Swift", at: Date(), count: 3)
        store.recordVisit(url: URL(string: "https://example.com/wiki_page")!, title: "Wiki", at: Date(), count: 3)
        // Not by the indexed lookup, which only sees hosts' beginnings.
        #expect(store.completionSites(for: "wiki").isEmpty)
        let found = store.completionSites(for: "wiki", afterSubdomain: true)
        #expect(found.map { HistoryStore.normalizedHost($0.entry.url) } == ["en.wikipedia.org"])
        // "_" and "%" are letters to look for, not patterns.
        #expect(store.completionSites(for: "w_ki", afterSubdomain: true).isEmpty)
        let sites = found.compactMap { entry, score in InlineCompletion.target(entry.url, wholePage: true).map { InlineCompletion.Site(url: $0, score: score) } }
        #expect(InlineCompletion.best(for: "wiki", among: sites)?.text == "wikipedia.org")
    }
}

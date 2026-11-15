import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Links a page opens: only to the web, never as yours, and a site's Block on opening apps always holds.
@MainActor
struct PageLinkTests {
    @Test func aPageOpensOnlyTheWeb() {
        let page = URL(string: "https://example.com/")
        for link in ["https://example.org/a", "http://example.org", "about:blank", "blob:https://example.com/1"] {
            #expect(Tab.route(forPageLink: URL(string: link)!, from: page) == .load, "\(link)")
        }
        // Another app's link asks, as the page's doing.
        for link in ["smb://evil/share", "zoommtg://zoom.us/join", "mailto:a@example.com", "afp://server", "vnc://host"] {
            #expect(Tab.route(forPageLink: URL(string: link)!, from: page) == .app, "\(link)")
        }
        // Never a file, a script, an extension's page or Zigzag's own; nor a data: page, which WebKit keeps a page from opening.
        for link in ["file:///etc/passwd", "javascript:alert(1)", "webkit-extension://abc/options.html", "zigzag://settings", "data:text/html,hi", "DATA:text/html;base64,PHA+"] {
            #expect(Tab.route(forPageLink: URL(string: link)!, from: page) == .refuse, "\(link)")
        }
        // A local page may link to the file beside it.
        #expect(Tab.route(forPageLink: URL(string: "file:///tmp/b.html")!, from: URL(string: "file:///tmp/a.html")) == .load)
    }

    @Test func blockAlwaysHolds() {
        // Block holds even for an address you typed: being yours only spares the question.
        #expect(ExternalLinks.verdict(byYou: true, clickedHere: true, scheme: "zoommtg", stored: "deny") == .block)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: true, scheme: "mailto", stored: "deny") == .block)
        #expect(ExternalLinks.verdict(byYou: true, clickedHere: false, scheme: "smb", stored: nil) == .open)
        // From a page, an app asks, unless the site was told it may.
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "smb", stored: nil) == .ask)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: true, scheme: "smb", stored: nil) == .ask)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "smb", stored: "allow") == .open)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: true, scheme: "mailto", stored: nil) == .open)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "mailto", stored: nil) == .ask)
    }

    /// A kept answer is trusted, and a question only writes one where it may live. An Allow on an http origin can
    /// only have been chosen in Site Controls — a question never writes one there — so it opens without asking, while
    /// nothing on an insecure page, in a foreign frame or in a private window can ever be written.
    @Test func anAnswerIsKeptOnlyWhereItMayBe() {
        #expect(ExternalLinks.saves(isPrivate: false, origin: "https://example.com", canRemember: true) == true)
        #expect(ExternalLinks.saves(isPrivate: true, origin: "https://example.com", canRemember: true) == false)
        #expect(ExternalLinks.saves(isPrivate: false, origin: nil, canRemember: true) == false)
        #expect(ExternalLinks.saves(isPrivate: false, origin: "http://example.com", canRemember: false) == false)
        #expect(ExternalLinks.saves(isPrivate: false, origin: "https://example.com", canRemember: false) == false)
        #expect(ExternalLinks.verdict(byYou: false, clickedHere: false, scheme: "zoommtg", stored: "allow") == .open)
    }

    @Test func everydayAppsOpenOnlyForALinkClickInThePage() {
        #expect(ExternalLinks.isEverydayClick(clickedHere: true, linkClick: true, sourceIsMainFrame: true, fromPDF: false))
        // A script on your click, a frame's link, a PDF's link, a page not in front: they ask.
        #expect(!ExternalLinks.isEverydayClick(clickedHere: true, linkClick: false, sourceIsMainFrame: true, fromPDF: false))
        #expect(!ExternalLinks.isEverydayClick(clickedHere: true, linkClick: true, sourceIsMainFrame: false, fromPDF: false))
        #expect(!ExternalLinks.isEverydayClick(clickedHere: true, linkClick: true, sourceIsMainFrame: true, fromPDF: true))
        #expect(!ExternalLinks.isEverydayClick(clickedHere: false, linkClick: true, sourceIsMainFrame: true, fromPDF: false))
    }

    @Test func aFrameWithNoHostIsNotThePage() {
        // The page itself, or a frame of the same site.
        #expect(!ExternalLinks.isForeign(askerHost: nil, pageHost: "zoom.us"))
        #expect(!ExternalLinks.isForeign(askerHost: "us02web.zoom.us", pageHost: "zoom.us"))
        #expect(ExternalLinks.isForeign(askerHost: "ads.example", pageHost: "zoom.us"))
        // A sandboxed or data: frame has no host: never the page's Always Open.
        #expect(ExternalLinks.isForeign(askerHost: "", pageHost: "zoom.us"))
        #expect(!ExternalLinks.isForeign(askerHost: "", pageHost: ""))
    }

    @Test func ownLoadMatchesOnlyItsAddress() throws {
        let typed = try #require(URL(string: "https://Example.com"))
        let own = Tab.OwnLoad(sender: .you, url: typed)
        #expect(Tab.ownSender(of: own, for: URL(string: "https://example.com/")) == .you)
        #expect(Tab.ownSender(of: own, for: typed) == .you)
        // The page's own navigation in flight when you pressed Return isn't yours.
        #expect(Tab.ownSender(of: own, for: URL(string: "ssh://example.com")) == nil)
        #expect(Tab.ownSender(of: own, for: URL(string: "https://example.com/other")) == nil)
        #expect(Tab.ownSender(of: nil, for: typed) == nil)
        #expect(Tab.ownSender(of: own, for: nil) == nil)
    }

    /// What WebKit tidies on the way still matches: a default port, "." and ".." in the path.
    @Test func ownLoadMatchesItsTidiedAddress() throws {
        let pairs = [("https://example.com:443/a", "https://example.com/a"), ("http://example.com:80", "http://example.com/"),
                     ("https://example.com/a/b/../c", "https://example.com/a/c"), ("https://example.com/./a/./", "https://example.com/a/"),
                     ("https://example.com/..", "https://example.com/"), ("https://example.com/a/..?q=1", "https://example.com/?q=1")]
        for (typed, asked) in pairs {
            let own = Tab.OwnLoad(sender: .you, url: try #require(URL(string: typed)))
            #expect(Tab.ownSender(of: own, for: URL(string: asked)) == .you, "\(typed)")
        }
        // Another port, or another path, is another address.
        #expect(!Tab.sameAddress(try #require(URL(string: "https://example.com:8443/")), try #require(URL(string: "https://example.com/"))))
        #expect(!Tab.sameAddress(try #require(URL(string: "http://example.com:443/")), try #require(URL(string: "http://example.com/"))))
        #expect(!Tab.sameAddress(try #require(URL(string: "https://example.com/a/../b")), try #require(URL(string: "https://example.com/a/b"))))
        #expect(Tab.withoutDotSegments("/a/b/c/./../../g") == "/a/g")
        #expect(Tab.withoutDotSegments("mid/content=5/../6") == "mid/6")
    }
}

/// When a page's link for another app may put its question up again.
struct ExternalLinkAskingTests {
    let key = "https://zoom.us|zoommtg"

    /// Two quick clicks never stack two questions: one is up, so the second waits for nothing.
    @Test func oneQuestionAtATimeEvenForClicks() {
        var asked = ExternalLinks.Asked()
        asked.asking.insert(key)
        let ask1 = asked.mayAsk(key, clickedHere: true, linkClick: true)
        #expect(!ask1)
        let ask2 = asked.mayAsk(key, clickedHere: false, linkClick: false)
        #expect(!ask2)
    }

    /// Put off: the page on its own waits a minute, but a click of yours asks at once (claude.ai's Open Claude).
    @Test func aClickAsksRightAfterAQuestionWasPutOff() {
        var asked = ExternalLinks.Asked()
        let now = Date()
        asked.putOff[key] = now.addingTimeInterval(60)
        let ask3 = asked.mayAsk(key, clickedHere: false, linkClick: false, now: now)
        #expect(!ask3)
        let ask4 = asked.mayAsk(key, clickedHere: true, linkClick: false, now: now)
        #expect(ask4)
        #expect(asked.putOff[key] == nil)
    }

    /// Questions nobody clicked for, from frames of many sites on one page, come one at a time and a few seconds apart.
    @Test func questionsOnTheirOwnAreSpacedAcrossFrames() {
        var asked = ExternalLinks.Asked()
        let now = Date()
        let page = "https://a.example"
        let first = asked.mayAsk("https://a.example|zoommtg", page: page, clickedHere: false, linkClick: false, now: now)
        #expect(first)
        asked.asking.insert("https://a.example|zoommtg")
        let whileUp = asked.mayAsk("https://b.example|zoommtg", page: page, clickedHere: false, linkClick: false, now: now.addingTimeInterval(1))
        #expect(!whileUp)
        asked.asking.removeAll()
        let tooSoon = asked.mayAsk("https://c.example|steam", page: page, clickedHere: false, linkClick: false, now: now.addingTimeInterval(2))
        #expect(!tooSoon)
        // Your own click always asks.
        let clicked = asked.mayAsk("https://d.example|zoommtg", page: page, clickedHere: true, linkClick: true, now: now.addingTimeInterval(3))
        #expect(clicked)
        let later = asked.mayAsk("https://e.example|zoommtg", page: page, clickedHere: false, linkClick: false,
                                 now: now.addingTimeInterval(ExternalLinks.Asked.unaskedGap + 1))
        #expect(later)
    }

    /// The gap is a page's site's: another site (another tab's meeting) asks at once.
    @Test func theGapIsPerSite() {
        var asked = ExternalLinks.Asked()
        let now = Date()
        let zoom = asked.mayAsk("https://zoom.us|zoommtg", page: "https://zoom.us", clickedHere: false, linkClick: false, now: now)
        #expect(zoom)
        let teams = asked.mayAsk("https://teams.example|msteams", page: "https://teams.example", clickedHere: false, linkClick: false, now: now.addingTimeInterval(1))
        #expect(teams)
        let zoomAgain = asked.mayAsk("https://zoom.us|zoommtg", page: "https://zoom.us", clickedHere: false, linkClick: false, now: now.addingTimeInterval(2))
        #expect(!zoomAgain)
    }

    /// Don't Open holds against a page's script riding on a click; only a link you click asks again.
    @Test func onlyALinkClickUndoesDontOpen() {
        var asked = ExternalLinks.Asked()
        asked.declined.insert(key)
        let ask5 = asked.mayAsk(key, clickedHere: false, linkClick: false)
        #expect(!ask5)
        let ask6 = asked.mayAsk(key, clickedHere: true, linkClick: false)
        #expect(!ask6)
        #expect(asked.declined.contains(key))
        let ask7 = asked.mayAsk(key, clickedHere: true, linkClick: true)
        #expect(ask7)
        #expect(!asked.declined.contains(key))
    }
    /// An extension sending the tab to an app's link (Downie's button): the web view shows the link as its address
    /// while it's decided, and the question is still the page's, so its Always Open counts (#239).
    @Test func anAppLinkZigzagSendsIsFromThePageItsOn() {
        let link = URL(string: "downie://XUOpenLink?url=https://www.instagram.com/reel/1")
        let page = ExternalLinks.page(showing: link, asker: "https://www.instagram.com")
        #expect(page == URL(string: "https://www.instagram.com"))
        #expect(SiteOrigin.of(page) == "https://www.instagram.com")
        #expect(!ExternalLinks.isForeign(askerHost: "www.instagram.com", pageHost: page?.host() ?? ""))
        // The page's own address stays the page, whoever asked.
        let zoom = URL(string: "https://zoom.us/j/1")
        #expect(ExternalLinks.page(showing: zoom, asker: "https://ads.example") == zoom)
        // Nothing asked: no page to keep an answer under.
        #expect(ExternalLinks.page(showing: link, asker: nil) == nil)
    }
}

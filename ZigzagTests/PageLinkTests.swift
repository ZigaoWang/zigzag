import AppKit
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
        // Never file, javascript, extension, zigzag or data: URLs (WebKit blocks data: top-level navigation).
        for link in ["file:///etc/passwd", "javascript:alert(1)", "webkit-extension://abc/options.html", "chrome-extension://abc/options.html", "zigzag://settings", "data:text/html,hi", "DATA:text/html;base64,PHA+"] {
            #expect(Tab.route(forPageLink: URL(string: link)!, from: page) == .refuse, "\(link)")
        }
        // A local page may link to the file beside it.
        #expect(Tab.route(forPageLink: URL(string: "file:///tmp/b.html")!, from: URL(string: "file:///tmp/a.html")) == .load)
    }

    /// What a click on a link opens: a new tab (⌘, in front with ⇧), Zigzag Mini (⇧), a download (⌥), or the page's own
    /// navigation. ⌘ is taken from the page outright; ⇧ and ⌥ are the page's, and count only once the page sends this
    /// tab to that same link right after the click (#322, #317).
    @Test func aClicksModifierDecidesWhereALinkOpens() {
        func activation(_ flags: NSEvent.ModifierFlags, type: WKNavigationType = .linkActivated,
                        button: Int = 0, mainFrame: Bool = true, followed: Tab.LinkActivation? = nil) -> Tab.LinkActivation {
            Tab.linkActivation(type: type, isMainFrame: mainFrame, modifiers: flags, buttonNumber: button, followed: followed)
        }
        #expect(activation([]) == .page)
        #expect(activation(.command) == .newTab(inFront: false))
        #expect(activation([.command, .shift]) == .newTab(inFront: true))
        #expect(activation(.shift) == .mini)
        #expect(activation(.option) == .download)
        // ⌘ is read before ⌥: ⌥⌘ opens a tab, as in Chrome.
        #expect(activation([.command, .option]) == .newTab(inFront: false))
        // A middle click opens a tab of its own, with or without a modifier.
        #expect(activation([], button: 4) == .newTab(inFront: false))
        #expect(activation(.shift, button: 4) == .newTab(inFront: true))
        // A page's own navigation is the page's, and so is a frame's link with ⇧, ⌥ or nothing held.
        #expect(activation(.shift, type: .other) == .page)
        #expect(activation(.command, type: .formSubmitted) == .page)
        #expect(activation(.shift, mainFrame: false) == .page)
        #expect(activation(.option, mainFrame: false) == .page)
        #expect(activation([], mainFrame: false) == .page)
        #expect(activation(.command, type: .other, mainFrame: false) == .page)
        #expect(activation([], type: .other, mainFrame: false, followed: .mini) == .page)
        // A frame's link opens a tab on ⌘ or a middle click, as on the page.
        #expect(activation(.command, mainFrame: false) == .newTab(inFront: false))
        #expect(activation([.command, .shift], mainFrame: false) == .newTab(inFront: true))
        #expect(activation([], button: 4, mainFrame: false) == .newTab(inFront: false))
        #expect(activation(.shift, button: 4, mainFrame: false) == .newTab(inFront: true))
        // Control is not one of the modifiers a click opens elsewhere with: ⌃-click is the page's context menu.
        #expect(activation(.control) == .page)
        // A page's own navigation is the click's only when it follows that very click: ⇧ opens Zigzag Mini, ⌥ downloads, and a
        // plain navigation of the page's own stays the page's.
        #expect(activation([], type: .other, followed: .mini) == .mini)
        #expect(activation([], type: .other, followed: .download) == .download)
        #expect(activation([], type: .other, followed: .page) == .page)
        // The guard every page gets takes ⌘ from the page, and reports ⇧ and ⌥ so the navigation after them is known.
        let guardScript = PageScripts.modifiedLinkClicks.source
        #expect(guardScript.contains("metaKey") && guardScript.contains("shiftKey") && guardScript.contains("altKey"))
        #expect(guardScript.contains("stopImmediatePropagation"))
        #expect(guardScript.contains("zigzagLinkClick"))
    }

    /// A ⇧-click on a link the page then sends this tab to opens Zigzag Mini, taken once: the same link, within the window.
    @Test func aShiftClickThePageFollowsOpensMiniOnce() {
        let tab = Tab(url: URL(string: "https://example.com/")!, spaceID: UUID())
        tab.modifiedClickFollowed(URL(string: "https://example.com/watch?v=1")!, mini: true, download: false)
        #expect(tab.followedActivation(for: URL(string: "https://example.com/watch?v=1")!) == .mini)
        // Taken once: a second navigation to the same link is the page's own.
        #expect(tab.followedActivation(for: URL(string: "https://example.com/watch?v=1")!) == nil)
        // Another link is another navigation.
        tab.modifiedClickFollowed(URL(string: "https://example.com/watch?v=1")!, mini: true, download: false)
        #expect(tab.followedActivation(for: URL(string: "https://example.com/other")!) == nil)
        // ⌥ is the download.
        tab.modifiedClickFollowed(URL(string: "https://example.com/file.zip")!, mini: false, download: true)
        #expect(tab.followedActivation(for: URL(string: "https://example.com/file.zip")!) == .download)
        // Nothing for a click that carried neither.
        tab.modifiedClickFollowed(URL(string: "https://example.com/plain")!, mini: false, download: false)
        #expect(tab.followedActivation(for: URL(string: "https://example.com/plain")!) == nil)
    }

    /// The mark goes when the moment passes: a page navigation a while after a ⇧-click is the page's own, not Zigzag Mini.
    @Test func aClickMarkGoesOnceTheMomentHasPassed() {
        let tab = Tab(url: URL(string: "https://example.com/")!, spaceID: UUID())
        tab.followedClick = (URL(string: "https://example.com/watch?v=1")!, .mini, Date().addingTimeInterval(-Tab.followedClickWindow - 1))
        #expect(tab.followedActivation(for: URL(string: "https://example.com/watch?v=1")!) == nil)
    }

    /// A page-handled ⇧-click opens Zigzag Mini; Command-Shift still opens a foreground tab.
    @Test func aPageHandledShiftClickIsMiniAndCommandShiftIsNot() {
        let tab = Tab(url: URL(string: "https://example.com/")!, spaceID: UUID())
        let clicked = URL(string: "https://example.com/watch?v=1")!
        tab.modifiedClickFollowed(clicked, mini: true, download: false)
        #expect(tab.newWindowActivation(for: clicked, type: .other, isMainFrame: true,
                                        modifiers: [], buttonNumber: 0) == .mini)
        // Taken once.
        #expect(tab.newWindowActivation(for: clicked, type: .other, isMainFrame: true,
                                        modifiers: [], buttonNumber: 0) == .page)
        // Native clicks use the existing precedence.
        #expect(tab.newWindowActivation(for: clicked, type: .linkActivated, isMainFrame: true,
                                        modifiers: [.shift], buttonNumber: 0) == .mini)
        #expect(tab.newWindowActivation(for: clicked, type: .linkActivated, isMainFrame: true,
                                        modifiers: [.command, .shift], buttonNumber: 0) == .newTab(inFront: true))
        // A frame's Shift-click stays the frame's.
        #expect(tab.newWindowActivation(for: clicked, type: .linkActivated, isMainFrame: false,
                                        modifiers: [.shift], buttonNumber: 0) == .page)
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

    /// Kept answers are trusted, and questions only store where allowed. An http Allow can only come from Site Controls, so it opens without asking; insecure pages, foreign frames and private windows never store.
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
        // A script after your click, a frame link, a PDF link, a background page: they ask.
        #expect(!ExternalLinks.isEverydayClick(clickedHere: true, linkClick: false, sourceIsMainFrame: true, fromPDF: false))
        #expect(!ExternalLinks.isEverydayClick(clickedHere: true, linkClick: true, sourceIsMainFrame: false, fromPDF: false))
        #expect(!ExternalLinks.isEverydayClick(clickedHere: true, linkClick: true, sourceIsMainFrame: true, fromPDF: true))
        #expect(!ExternalLinks.isEverydayClick(clickedHere: false, linkClick: true, sourceIsMainFrame: true, fromPDF: false))
    }

    @Test func aFrameWithNoHostIsNotThePage() {
        // The page itself or a same-site frame.
        #expect(!ExternalLinks.isForeign(askerHost: nil, pageHost: "zoom.us"))
        #expect(!ExternalLinks.isForeign(askerHost: "us02web.zoom.us", pageHost: "zoom.us"))
        #expect(ExternalLinks.isForeign(askerHost: "ads.example", pageHost: "zoom.us"))
        // Sandboxed or data: frames have no host, so never the page's Always Open.
        #expect(ExternalLinks.isForeign(askerHost: "", pageHost: "zoom.us"))
        #expect(!ExternalLinks.isForeign(askerHost: "", pageHost: ""))
    }

    @Test func ownLoadMatchesOnlyItsAddress() throws {
        let typed = try #require(URL(string: "https://Example.com"))
        let own = Tab.OwnLoad(sender: .you, url: typed)
        #expect(Tab.ownSender(of: own, for: URL(string: "https://example.com/")) == .you)
        #expect(Tab.ownSender(of: own, for: typed) == .you)
        // The page's own in-flight navigation when you pressed Return isn't yours.
        #expect(Tab.ownSender(of: own, for: URL(string: "ssh://example.com")) == nil)
        #expect(Tab.ownSender(of: own, for: URL(string: "https://example.com/other")) == nil)
        #expect(Tab.ownSender(of: nil, for: typed) == nil)
        #expect(Tab.ownSender(of: own, for: nil) == nil)
    }

    /// Still matches after WebKit normalizes the URL: default port, "." and "..".
    @Test func ownLoadMatchesItsTidiedAddress() throws {
        let pairs = [("https://example.com:443/a", "https://example.com/a"), ("http://example.com:80", "http://example.com/"),
                     ("https://example.com/a/b/../c", "https://example.com/a/c"), ("https://example.com/./a/./", "https://example.com/a/"),
                     ("https://example.com/..", "https://example.com/"), ("https://example.com/a/..?q=1", "https://example.com/?q=1")]
        for (typed, asked) in pairs {
            let own = Tab.OwnLoad(sender: .you, url: try #require(URL(string: typed)))
            #expect(Tab.ownSender(of: own, for: URL(string: asked)) == .you, "\(typed)")
        }
        // A different port or path is a different address.
        #expect(!Tab.sameAddress(try #require(URL(string: "https://example.com:8443/")), try #require(URL(string: "https://example.com/"))))
        #expect(!Tab.sameAddress(try #require(URL(string: "http://example.com:443/")), try #require(URL(string: "http://example.com/"))))
        #expect(!Tab.sameAddress(try #require(URL(string: "https://example.com/a/../b")), try #require(URL(string: "https://example.com/a/b"))))
        #expect(Tab.withoutDotSegments("/a/b/c/./../../g") == "/a/g")
        #expect(Tab.withoutDotSegments("mid/content=5/../6") == "mid/6")
    }

    /// A schemeless address falls back to http once, at the same address, only when https isn't served; never for HSTS sites.
    @Test func aTypedAddressFallsBackToHTTPOnlyWhereHTTPSCantBeReached() throws {
        let secure = try #require(URL(string: "https://LocalTest.me:3600"))
        let plain = try #require(URL(string: "http://LocalTest.me:3600"))
        let pending = Tab.HTTPFallback(secure: secure, plain: plain, sender: .you)
        func error(_ code: Int) -> NSError { NSError(domain: NSURLErrorDomain, code: code) }
        // Same address after WebKit normalizes it.
        let failing = URL(string: "https://localtest.me:3600/")
        #expect(Tab.fallbackURL(for: pending, after: error(NSURLErrorSecureConnectionFailed), failing: failing, strictTransport: false) == plain)
        #expect(Tab.fallbackURL(for: pending, after: error(NSURLErrorCannotConnectToHost), failing: secure, strictTransport: false) == plain)
        // Certificate errors keep the warning; timeouts, lost connections and DNS failures wouldn't work over http either.
        for code in [NSURLErrorServerCertificateUntrusted, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost] {
            #expect(Tab.fallbackURL(for: pending, after: error(code), failing: secure, strictTransport: false) == nil, "\(code)")
        }
        let refused = error(NSURLErrorSecureConnectionFailed)
        // Only at the original address: not after a redirect, nor when http itself failed.
        #expect(Tab.fallbackURL(for: pending, after: refused, failing: URL(string: "https://localtest.me:3600/login"), strictTransport: false) == nil)
        #expect(Tab.fallbackURL(for: pending, after: refused, failing: plain, strictTransport: false) == nil)
        #expect(Tab.fallbackURL(for: pending, after: refused, failing: nil, strictTransport: false) == nil)
        #expect(Tab.fallbackURL(for: nil, after: refused, failing: secure, strictTransport: false) == nil)
        // HSTS sites never fall back.
        #expect(Tab.fallbackURL(for: pending, after: refused, failing: secure, strictTransport: true) == nil)
    }

    /// Only the scheme changes; port, path, query and fragment are kept.
    @Test func theAddressOverHTTPIsTheSameAddress() {
        #expect(Tab.overHTTP(URL(string: "https://localtest.me:3600/x?y=1#/login")!)?.absoluteString == "http://localtest.me:3600/x?y=1#/login")
        #expect(Tab.overHTTP(URL(string: "HTTPS://example.com")!)?.absoluteString == "http://example.com")
        #expect(Tab.overHTTP(URL(string: "http://example.com")!) == nil)
        #expect(Tab.overHTTP(URL(string: "file:///tmp/a.html")!) == nil)
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

    /// Unprompted questions from many frames on one page come one at a time, a few seconds apart.
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
        // A click always asks.
        let clicked = asked.mayAsk("https://d.example|zoommtg", page: page, clickedHere: true, linkClick: true, now: now.addingTimeInterval(3))
        #expect(clicked)
        let later = asked.mayAsk("https://e.example|zoommtg", page: page, clickedHere: false, linkClick: false,
                                 now: now.addingTimeInterval(ExternalLinks.Asked.unaskedGap + 1))
        #expect(later)
    }

    /// The gap is per page site; another site asks immediately.
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
    /// A ⇧-click a page handles itself comes back as its own `window.open`: the Mini is offered no WebKit configuration,
    /// since no web view is returned for it to belong to.
    @Test func aPageHandledShiftClickOffersTheMiniNoConfiguration() {
        let host = InPageMiniRecordingHost()
        let tab = Tab(url: URL(string: "https://example.com/")!, spaceID: UUID())
        tab.host = host
        #expect(tab.openPageHandledMini(URL(string: "https://example.com/watch?v=1")!))
        #expect(host.configurations.count == 1)
        #expect(host.configurations[0] == nil)
    }

    /// An extension sending the tab to an app link (Downie): the link shows as the address while deciding, but the question belongs to the page, so its Always Open applies (#239).
    @Test func anAppLinkZigzagSendsIsFromThePageItsOn() {
        let link = URL(string: "downie://XUOpenLink?url=https://www.instagram.com/reel/1")
        let page = ExternalLinks.page(showing: link, asker: "https://www.instagram.com")
        #expect(page == URL(string: "https://www.instagram.com"))
        #expect(SiteOrigin.of(page) == "https://www.instagram.com")
        #expect(!ExternalLinks.isForeign(askerHost: "www.instagram.com", pageHost: page?.host() ?? ""))
        // The page URL stays the page, whoever asked.
        let zoom = URL(string: "https://zoom.us/j/1")
        #expect(ExternalLinks.page(showing: zoom, asker: "https://ads.example") == zoom)
        // No asker: no page to store an answer under.
        #expect(ExternalLinks.page(showing: link, asker: nil) == nil)
    }
}

/// A tab host that records the configuration its in-page Mini was offered.
@MainActor
private final class InPageMiniRecordingHost: TabHost {
    var configurations: [WKWebViewConfiguration?] = []
    var hostWindow: NSWindow? { nil }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender) {}
    func tab(_ tab: Tab, openInPageMini url: URL, configuration: WKWebViewConfiguration?,
             by sender: Tab.LoadSender) -> Bool {
        configurations.append(configuration)
        return true
    }
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
             features: WKWindowFeatures) -> WKWebView? { nil }
    func tabDidRequestClose(_ tab: Tab) {}
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tab(_ tab: Tab, hoveringLink url: URL?) {}
    func tabWantsToBeShown(_ tab: Tab) {}
}

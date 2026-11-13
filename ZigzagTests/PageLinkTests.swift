import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Links a page opens: only to the web, never as yours, and a site's Block on opening apps always holds.
@MainActor
struct PageLinkTests {
    @Test func aPageOpensOnlyTheWeb() {
        let page = URL(string: "https://example.com/")
        for link in ["https://example.org/a", "http://example.org", "about:blank", "data:text/html,hi", "blob:https://example.com/1"] {
            #expect(Tab.route(forPageLink: URL(string: link)!, from: page) == .load, "\(link)")
        }
        // Another app's link asks, as the page's doing.
        for link in ["smb://evil/share", "zoommtg://zoom.us/join", "mailto:a@example.com", "afp://server", "vnc://host"] {
            #expect(Tab.route(forPageLink: URL(string: link)!, from: page) == .app, "\(link)")
        }
        // Never a file, a script, an extension's page or Zigzag's own.
        for link in ["file:///etc/passwd", "javascript:alert(1)", "webkit-extension://abc/options.html", "zigzag://settings"] {
            #expect(Tab.route(forPageLink: URL(string: link)!, from: page) == .refuse, "\(link)")
        }
        // A local page may link to the file beside it.
        #expect(Tab.route(forPageLink: URL(string: "file:///tmp/b.html")!, from: URL(string: "file:///tmp/a.html")) == .load)
    }

    @Test func blockAlwaysHolds() {
        // Block holds even for an address you typed: being yours only spares the question.
        #expect(ExternalLinks.verdict(byYou: true, decision: false, clickedHere: true, scheme: "zoommtg") == .block)
        #expect(ExternalLinks.verdict(byYou: false, decision: false, clickedHere: true, scheme: "mailto") == .block)
        #expect(ExternalLinks.verdict(byYou: true, decision: nil, clickedHere: false, scheme: "smb") == .open)
        // From a page, an app asks, unless the site was told it may.
        #expect(ExternalLinks.verdict(byYou: false, decision: nil, clickedHere: false, scheme: "smb") == .ask)
        #expect(ExternalLinks.verdict(byYou: false, decision: nil, clickedHere: true, scheme: "smb") == .ask)
        #expect(ExternalLinks.verdict(byYou: false, decision: true, clickedHere: false, scheme: "smb") == .open)
        #expect(ExternalLinks.verdict(byYou: false, decision: nil, clickedHere: true, scheme: "mailto") == .open)
        #expect(ExternalLinks.verdict(byYou: false, decision: nil, clickedHere: false, scheme: "mailto") == .ask)
    }
}

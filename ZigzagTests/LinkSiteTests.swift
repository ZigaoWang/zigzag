import Foundation
import Testing
@testable import Zigzag

/// Which links leave a pinned tab's site, and so open beside it.
@MainActor
struct LinkSiteTests {
    @Test func sameSite() {
        let site = { (s: String) in Tab.site(of: URL(string: s)!) }
        #expect(site("https://mail.google.com/mail") == site("https://accounts.google.com/signin"))
        #expect(site("https://www.bbc.co.uk/news") == "bbc.co.uk")
        #expect(site("https://news.bbc.co.uk") == "bbc.co.uk")
        #expect(site("https://github.com/x") == "github.com")
        #expect(site("https://github.com") != site("https://gitlab.com"))
    }
}

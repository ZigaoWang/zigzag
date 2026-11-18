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

    /// Sites under a public suffix (vercel.app, github.io) are separate, so a web app never claims another's page.
    @Test func sitesUnderASharedHostAreApart() throws {
        let site = { (s: String) in Tab.site(of: URL(string: s)!) }
        #expect(site("https://myapp.vercel.app/") == "myapp.vercel.app")
        #expect(site("https://evil.vercel.app/") != site("https://myapp.vercel.app/"))
        #expect(site("https://alice.github.io/") != site("https://bob.github.io/"))
        #expect(site("https://a.b.example.com.au/") == "example.com.au")
        #expect(site("http://192.168.1.1/") == "192.168.1.1")
        #expect(site("http://localhost:3000/") == "localhost")
    }
}

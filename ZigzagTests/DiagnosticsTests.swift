import Foundation
import Testing
@testable import Zigzag

/// The diagnostics record names sites, never addresses or anything personal a page's error might quote.
struct DiagnosticsTests {
    @Test func addressesShrinkToTheirSite() {
        let text = Diagnostics.clean("Failed to fetch https://login.example.com/oauth?token=secret#frag from page")
        #expect(text == "Failed to fetch login.example.com from page")
        #expect(!Diagnostics.clean("see http://a.b/c?d=e").contains("d=e"))
    }

    @Test func emailsAreHidden() {
        #expect(Diagnostics.clean("No account for sam@example.com") == "No account for (email)")
    }

    @Test func longTextIsCut() {
        let text = Diagnostics.clean(String(repeating: "x", count: 500))
        #expect(text.count == 201)
        #expect(text.hasSuffix("…"))
    }

    @Test func linesAreOne() {
        #expect(!Diagnostics.clean("one\ntwo").contains("\n"))
    }

    @Test func errorsNameTheirCode() {
        let error = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSLocalizedDescriptionKey: "Secure connection failed"])
        #expect(Diagnostics.describe(error) == "Secure connection failed (NSURLErrorDomain -1200)")
    }
}

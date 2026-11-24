import Foundation
import Testing
import WebKit
@testable import Zigzag

/// chrome-extension:// addresses, as extensions and people write them, open the extension's page at Zigzag's own
/// webkit-extension:// address (#475).
@MainActor
struct ChromeExtensionAddressTests {
    private let id = "nlbejmccbhkncgokjcmghpfloaajcffj"

    @Test func chromesAddressBecomesZigzagsOwn() {
        let address = { (text: String) in Tab.extensionPageAddress(URL(string: text)!).absoluteString }
        #expect(address("chrome-extension://\(id)/pages/options.html?tab=2#about") == "webkit-extension://\(id)/pages/options.html?tab=2#about")
        #expect(address("CHROME-EXTENSION://\(id.uppercased())/panel/index.html") == "webkit-extension://\(id)/panel/index.html")
        #expect(address("chrome-extension://\(id)") == "webkit-extension://\(id)/")
        // Anything else is left as it was.
        for other in ["https://example.com/", "webkit-extension://\(id)/a.html", "moz-extension://\(id)/a.html", "chrome-extension:nothing"] {
            #expect(address(other) == other, "\(other)")
        }
    }

    @Test func typedItOpens() {
        let typed = CommandRanker.destination(from: "chrome-extension://\(id)/pages/options.html")
        #expect(typed?.url.absoluteString == "chrome-extension://\(id)/pages/options.html")
        #expect(typed?.httpFallback == false)
    }

    @Test func aTabGivenItShowsZigzagsAddress() {
        let tab = Tab(url: URL(string: "chrome-extension://\(id)/pages/welcome.html")!, spaceID: UUID())
        #expect(tab.url?.absoluteString == "webkit-extension://\(id)/pages/welcome.html")
    }

    @Test func aWebsiteCantSendATabThere() {
        #expect(Tab.route(forPageLink: URL(string: "chrome-extension://\(id)/a.html")!, from: URL(string: "https://example.com/")) == .refuse)
    }
}

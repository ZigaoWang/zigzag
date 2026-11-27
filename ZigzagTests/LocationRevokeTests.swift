import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A site's location, taken away from a page that is open now (#545). WebKit asks Zigzag whether to grant it when the
/// page asks; a page already watching keeps receiving positions until something stops it. A Block does: a request from
/// that page then fails at once with the web platform's permission error, and a reload asks again, where the kept Block
/// refuses it without a question.
@MainActor
@Suite(.serialized)
struct LocationRevokeTests {
    private let site = "https://maps.example.com"

    @Test func theGuardStopsAPagesWatch() async throws {
        // A real tab's own web view, so the page goes through the same setup the app gives it.
        let tab = Tab(url: URL(string: site + "/"), spaceID: UUID())
        let webView = tab.ensureWebView()
        let token = UUID().uuidString
        webView.loadHTMLString("<p id='\(token)'>hi</p>", baseURL: URL(string: site + "/"))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await webView.evaluateJavaScript("!!document.getElementById('\(token)')")) as? Bool == true { break }
        }

        // A Block, as LivePermissions delivers it to an open page.
        PageLocation.shared.revoke(origin: site, in: tab)

        // A request from that page now fails at once, with the permission error the web platform uses, rather than
        // waiting on a prompt or a watch that will never answer.
        _ = try? await webView.evaluateJavaScript("""
        window.zigzagAsked = 'none';
        navigator.geolocation.getCurrentPosition(
          function () { window.zigzagAsked = 'position'; },
          function (e) { window.zigzagAsked = 'error:' + e.code; });
        """)
        var answer = "none"
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            answer = (try? await webView.evaluateJavaScript("window.zigzagAsked")) as? String ?? "none"
            if answer != "none" { break }
        }
        #expect(answer == "error:1", "got \(answer)")
    }
}

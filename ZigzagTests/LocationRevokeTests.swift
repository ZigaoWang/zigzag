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

    /// The other direction: a site switched to Allow gets its location back on the page that is open, without a
    /// reload. This is what the guard must undo — a page that was refused on an earlier answer would otherwise stay
    /// refused until it reloaded, which is the complaint this change answers.
    @Test func theGuardComesOffAgainForAnAllowedSite() async throws {
        let tab = Tab(url: URL(string: site + "/"), spaceID: UUID())
        let webView = tab.ensureWebView()
        let token = UUID().uuidString
        webView.loadHTMLString("<p id='\(token)'>hi</p>", baseURL: URL(string: site + "/"))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await webView.evaluateJavaScript("!!document.getElementById('\(token)')")) as? Bool == true { break }
        }

        PageLocation.shared.revoke(origin: site, in: tab)
        // The guard is on: the method the guard installed is an own property of `navigator.geolocation`.
        let guarded = (try? await webView.evaluateJavaScript(
            "Object.prototype.hasOwnProperty.call(navigator.geolocation, 'getCurrentPosition')")) as? Bool
        #expect(guarded == true)

        PageLocation.shared.allow(origin: site, in: tab)
        // The guard is off: the native method is reached through the prototype again, not a copy the guard left.
        let restored = (try? await webView.evaluateJavaScript(
            "Object.prototype.hasOwnProperty.call(navigator.geolocation, 'getCurrentPosition')")) as? Bool
        #expect(restored == false, "an allowed site must get the browser's own geolocation back")

        // And it works: a watch started after the Allow is a real watch, not the guard's immediate refusal. The
        // position itself may never arrive without Core Location, so this asserts only that no permission error did.
        _ = try? await webView.evaluateJavaScript("""
        window.zigzagWatch = 'none';
        navigator.geolocation.watchPosition(
          function () { window.zigzagWatch = 'position'; },
          function (e) { window.zigzagWatch = 'error:' + e.code; });
        """)
        var answer = "none"
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            answer = (try? await webView.evaluateJavaScript("window.zigzagWatch")) as? String ?? "none"
            if answer != "none" { break }
        }
        #expect(answer != "error:1", "a watch after an Allow must not be refused as blocked")
    }
}

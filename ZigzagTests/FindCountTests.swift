import AppKit
import Testing
import WebKit
@testable import Zigzag

/// The find bar's count is WebKit's own (#180): the matches it goes through and marks, and no others. Checked on a
/// page with hidden text, a word split across inline elements, two blocks side by side and a frame.
@MainActor
@Suite(.serialized)
struct FindCountTests {
    private final class Marker {}

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page() async throws -> (WKWebView, NSWindow) {
        let url = try #require(Bundle(for: Marker.self).url(forResource: "find-count", withExtension: "html"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        // In a window, as in the browser: find draws its match there.
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // The frame's own page loads on its own.
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if await PageFind.count("banana", in: webView) == 3 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (webView, window)
    }

    @Test func webKitsFindIsThere() {
        #expect(PageFind.isAvailable)
    }

    @Test func countsWhatIsShownAndNothingElse() async throws {
        let (webView, window) = try await page()
        defer { window.close() }
        // Two in plain text (one in capitals) and one split across bold and italic; none of the hidden ones.
        #expect(await PageFind.count("apple", in: webView) == 3)
        #expect(await PageFind.count("APPLE", in: webView) == 3)
        // One on the page, two in the frame.
        #expect(await PageFind.count("banana", in: webView) == 3)
        // Blocks side by side don't run together.
        #expect(await PageFind.count("pearplum", in: webView) == 0)
        #expect(await PageFind.count("pear", in: webView) == 1)
        #expect(await PageFind.count("not on the page", in: webView) == 0)
    }

    /// Going through the matches says the same count each time, and where you are, wrapping around.
    @Test func findGoesThroughTheMatchesItCounts() async throws {
        let (webView, window) = try await page()
        defer { window.close() }
        var places: [Int] = []
        for _ in 0..<4 {
            let result = try #require(await PageFind.find("apple", in: webView, backwards: false))
            #expect(result.count == 3)
            places.append(try #require(result.index))
        }
        #expect(places == [0, 1, 2, 0])
        let back = try #require(await PageFind.find("apple", in: webView, backwards: true))
        #expect(back.count == 3)
        #expect(back.index == 2)
        let none = try #require(await PageFind.find("pearplum", in: webView, backwards: false))
        #expect(none.count == 0)
    }

    /// The count follows the page as it changes.
    @Test func countsThePageAsItIsNow() async throws {
        let (webView, window) = try await page()
        defer { window.close() }
        _ = try await webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<p>one more apple</p>'); 0")
        #expect(await PageFind.count("apple", in: webView) == 4)
        _ = try await webView.evaluateJavaScript("document.querySelector('.gone').style.display = 'block'; 0")
        #expect(await PageFind.count("apple", in: webView) == 6)
    }
}

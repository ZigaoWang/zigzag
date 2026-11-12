import AppKit
import WebKit

/// Find on a web page with WebKit's own find, the one Safari uses (#180). It counts the very matches it goes through
/// and marks: text that's on screen (not hidden elements, scripts or styles), words split across bold or links, text
/// in frames, case aside. Counting the page's text with a script of our own could never quite agree with it, so the
/// "3 of 12" came out high on one page and low on the next.
///
/// WebKit says how many it found to a find delegate (`_WKFindDelegate`), not in a completion handler; neither is
/// public API, but both are long-standing. Without them, `isAvailable` is false and the public find is used, with no
/// count.
@MainActor
final class PageFind: NSObject {
    /// What a search found.
    struct Result: Equatable {
        /// How many matches the page has: more than `PageFind.maxCount` is `maxCount + 1`.
        var count: Int
        /// The one now selected, from 0, when WebKit says.
        var index: Int?

        var isOverMax: Bool { count > PageFind.maxCount }
    }

    /// Counted up to this many, as Safari does: past it, "More than 1,000 matches".
    static let maxCount = 1000

    private static let findSelector = NSSelectorFromString("_findString:options:maxCount:")
    private static let countSelector = NSSelectorFromString("_countStringMatches:options:maxCount:")
    private static let setDelegateSelector = NSSelectorFromString("_setFindDelegate:")

    static var isAvailable: Bool {
        [findSelector, countSelector, setDelegateSelector].allSatisfy { WKWebView.instancesRespond(to: $0) }
    }

    /// `_WKFindOptions`.
    private struct Options: OptionSet {
        let rawValue: UInt
        static let caseInsensitive = Options(rawValue: 1 << 0)
        static let backwards = Options(rawValue: 1 << 3)
        static let wrapAround = Options(rawValue: 1 << 4)
        static let showFindIndicator = Options(rawValue: 1 << 6)
        static let determineMatchIndex = Options(rawValue: 1 << 9)
    }

    private weak var webView: WKWebView?
    /// Searches waiting for WebKit's answer, oldest first; answers come in the order they were asked.
    private var waiting: [(id: Int, query: String, resume: (Result?) -> Void)] = []
    private var nextID = 0

    private init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    private static var finderKey = 0

    /// The web view's own finder: kept with it, as WebKit holds its find delegate weakly.
    private static func finder(for webView: WKWebView) -> PageFind {
        if let finder = objc_getAssociatedObject(webView, &finderKey) as? PageFind { return finder }
        let finder = PageFind(webView: webView)
        objc_setAssociatedObject(webView, &finderKey, finder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.perform(setDelegateSelector, with: finder)
        return finder
    }

    /// Goes to the next match (the previous one, `backwards`) and selects it, wrapping around, and says how many there
    /// are and which one it's on. Nil when WebKit didn't answer.
    static func find(_ query: String, in webView: WKWebView, backwards: Bool) async -> Result? {
        var options: Options = [.caseInsensitive, .wrapAround, .showFindIndicator, .determineMatchIndex]
        if backwards { options.insert(.backwards) }
        return await finder(for: webView).ask(findSelector, query: query, options: options)
    }

    /// How many matches the page has, without moving to one.
    static func count(_ query: String, in webView: WKWebView) async -> Int? {
        await finder(for: webView).ask(countSelector, query: query, options: [.caseInsensitive])?.count
    }

    private func ask(_ selector: Selector, query: String, options: Options) async -> Result? {
        guard let webView, !query.isEmpty else { return nil }
        nextID += 1
        let id = nextID
        return await withCheckedContinuation { continuation in
            waiting.append((id, query, { continuation.resume(returning: $0) }))
            typealias Call = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
            let call = unsafeBitCast(webView.method(for: selector), to: Call.self)
            call(webView, selector, query as NSString, options.rawValue, UInt(Self.maxCount))
            // An answer that never comes (the page went away) doesn't keep the find bar waiting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.answer(id: id, with: nil) }
        }
    }

    private func answer(id: Int, with result: Result?) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).resume(result)
    }

    /// The oldest search for `string` hears its answer.
    private func answer(_ string: String, with result: Result?) {
        guard let entry = waiting.first(where: { $0.query == string }) else { return }
        answer(id: entry.id, with: result)
    }

    private static func count(_ matches: UInt) -> Int { matches > UInt(maxCount) ? maxCount + 1 : Int(matches) }

    @objc(_webView:didCountMatches:forString:)
    func webView(_ webView: WKWebView, didCountMatches matches: UInt, forString string: NSString) {
        answer(string as String, with: Result(count: Self.count(matches), index: nil))
    }

    @objc(_webView:didFindMatches:forString:withMatchIndex:)
    func webView(_ webView: WKWebView, didFindMatches matches: UInt, forString string: NSString, withMatchIndex index: Int) {
        let count = Self.count(matches)
        answer(string as String, with: Result(count: count, index: (0..<count).contains(index) ? index : nil))
    }

    @objc(_webView:didFailToFindString:)
    func webView(_ webView: WKWebView, didFailToFindString string: NSString) {
        answer(string as String, with: Result(count: 0, index: nil))
    }
}

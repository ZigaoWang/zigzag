import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Find marks every match at once and puts a tick for each along the page's edge (#244), without touching the page.
@MainActor
@Suite(.serialized)
struct FindMarksTests {
    // MARK: Ticks

    @Test func ticksSitWhereTheirMatchesAre() {
        let snapshot = FindMarks.Snapshot(marks: [0, 0.5, 1], current: nil, count: 3, dark: false)
        let rects = FindMarks.tickRects(snapshot, height: 216, width: 12, scale: 2)
        #expect(rects.map(\.index) == [0, 1, 2])
        // The ends of the track, clear of the page's corners, and its middle.
        #expect(rects[0].rect == CGRect(x: 3, y: 8, width: 6, height: 2))
        #expect(rects[1].rect == CGRect(x: 3, y: 107, width: 6, height: 2))
        #expect(rects[2].rect == CGRect(x: 3, y: 206, width: 6, height: 2))
    }

    @Test func ticksLandOnPixels() {
        let snapshot = FindMarks.Snapshot(marks: [0.3337], current: nil, count: 1, dark: false)
        let y2 = FindMarks.tickRects(snapshot, height: 301, width: 12, scale: 2)[0].rect.minY
        #expect((y2 * 2).rounded() == y2 * 2)
        let y1 = FindMarks.tickRects(snapshot, height: 301, width: 12, scale: 1)[0].rect.minY
        #expect(y1.rounded() == y1)
    }

    @Test func theCurrentTickIsDrawnLast() {
        let snapshot = FindMarks.Snapshot(marks: [0.1, 0.2, 0.3], current: 1, count: 3, dark: false)
        let rects = FindMarks.tickRects(snapshot, height: 100, width: 12, scale: 2)
        #expect(rects.map(\.index) == [0, 2, 1])
    }

    @Test func noMatchesNoTicks() {
        #expect(FindMarks.tickRects(.empty, height: 100, width: 12, scale: 2).isEmpty)
        let one = FindMarks.Snapshot(marks: [0.5], current: 0, count: 1, dark: false)
        #expect(FindMarks.tickRects(one, height: 17, width: 12, scale: 2).isEmpty)
    }

    @Test func aClickTakesTheNearestTick() {
        let snapshot = FindMarks.Snapshot(marks: [0.1, 0.12, 0.8], current: nil, count: 3, dark: false)
        let rects = FindMarks.tickRects(snapshot, height: 1018, width: 12, scale: 2)
        #expect(FindMarks.tick(at: 109, in: rects) == 0)
        #expect(FindMarks.tick(at: 129, in: rects) == 1)
        #expect(FindMarks.tick(at: 812, in: rects) == 2)
        // Between ticks, it's the page's.
        #expect(FindMarks.tick(at: 500, in: rects) == nil)
    }

    @Test func snapshotsReadTheScriptsAnswer() {
        let snapshot = FindMarks.Snapshot(["marks": [-0.2, 0.5, 1.4], "current": 2, "count": 3, "dark": true])
        #expect(snapshot == FindMarks.Snapshot(marks: [0, 0.5, 1], current: 2, count: 3, dark: true))
        // A current match that isn't marked is none.
        #expect(FindMarks.Snapshot(["marks": [0.5], "current": 4, "count": 1])?.current == nil)
        #expect(FindMarks.Snapshot(["marks": [0.5], "current": -1, "count": 1])?.current == nil)
        #expect(FindMarks.Snapshot("nonsense") == nil)
    }

    @Test func highlightNamesSayNothingOfZigzag() {
        let names = FindMarks.Names.random()
        let all = [names.all, names.current, names.allDark, names.currentDark]
        #expect(Set(all).count == 4)
        #expect(all.allSatisfy { !$0.lowercased().contains("zigzag") && !$0.lowercased().contains("find") })
        #expect(FindMarks.css(names).contains("::highlight(\(names.current))"))
    }

    // MARK: On a page

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func page(_ body: String) async -> (WKWebView, NSWindow) {
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
            webView.loadHTMLString("<!doctype html><html><head><meta charset=utf-8></head><body>\(body)</body></html>", baseURL: URL(string: "https://example.com/"))
        }
        return (webView, window)
    }

    private func pageScript(_ webView: WKWebView, _ source: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test func marksAvailable() {
        #expect(FindMarks.isAvailable)
    }

    /// Finding and closing leaves the page's DOM exactly as it was: not a node or attribute added, and nothing the
    /// page's own observer hears of.
    @Test func thePageIsLeftUntouched() async throws {
        let (webView, window) = await page("""
        <p id=a>An apple a day.</p><p>APPLE pie, and an <b>ap</b><i>ple</i>.</p><div style="display:none">apple hidden</div>
        <script>window.heard = 0; new MutationObserver((m) => { window.heard += m.length; })
          .observe(document, { subtree: true, childList: true, attributes: true, characterData: true });</script>
        """)
        defer { window.close() }
        let before = try await pageScript(webView, "return document.documentElement.outerHTML") as? String
        let found = try #require(await PageFind.find("apple", in: webView, backwards: false, showsIndicator: false))
        #expect(found.count == 3)
        let marked = try #require(await FindMarks.mark("apple", in: webView))
        #expect(marked.count == 3)
        #expect(marked.marks.count == 3)
        #expect(marked.current == found.index)
        await FindMarks.prepare(in: webView)
        _ = await PageFind.find("apple", in: webView, backwards: false, showsIndicator: false)
        _ = await FindMarks.mark("apple", in: webView)
        FindMarks.clear(in: webView)
        _ = try await webView.runOwnScript("return 0", asFunction: true)
        #expect(try await webView.runOwnScript("return globalThis.__zigzagFind.state().highlights", asFunction: true) as? Int == 0)
        let after = try await pageScript(webView, "return document.documentElement.outerHTML") as? String
        #expect(before != nil)
        #expect(after == before)
        #expect(try await pageScript(webView, "return window.heard") as? Int == 0)
    }

    /// Text WebKit paints no highlight on (a button's, a flex box's, unselectable text) is boxed, and the boxes go
    /// when find closes (#329).
    @Test func textWithoutHighlightsIsBoxed() async throws {
        let (webView, window) = await page("""
        <p>kiwi</p><button>kiwi</button><div style="display:flex">kiwi</div><div>kiwi<div>block</div></div>
        <p><span style="-webkit-user-select:none">kiwi</span></p><p><a href=#>kiwi</a></p>
        """)
        defer { window.close() }
        let before = try await pageScript(webView, "return document.documentElement.outerHTML") as? String
        _ = try #require(await PageFind.find("kiwi", in: webView, backwards: false, showsIndicator: false))
        #expect(try #require(await FindMarks.mark("kiwi", in: webView)).count == 6)
        #expect(try await findState(webView, "boxed") as? Int == 4)
        #expect(try await findState(webView, "highlights") as? Int == 2)
        FindMarks.clear(in: webView)
        #expect(try await findState(webView, "boxed") as? Int == 0)
        #expect(try await pageScript(webView, "return document.documentElement.outerHTML") as? String == before)
    }

    /// Going through the matches, the one WebKit lands on is the one marked stronger, both ways, wrapping around.
    @Test func theCurrentMatchFollowsTheFind() async throws {
        let (webView, window) = await page("<p>one apple</p><p>two apple</p><p>three apple</p>")
        defer { window.close() }
        var places: [Int?] = []
        var indexes: [Int?] = []
        func step(_ backwards: Bool) async throws {
            await FindMarks.prepare(in: webView)
            let found = try #require(await PageFind.find("apple", in: webView, backwards: backwards, showsIndicator: false))
            let marked = try #require(await FindMarks.mark("apple", in: webView))
            indexes.append(found.index)
            places.append(marked.current)
        }
        for _ in 0..<4 { try await step(false) }
        try await step(true)
        try await step(true)
        #expect(indexes == [0, 1, 2, 0, 2, 1])
        #expect(places == indexes)
        // The selection is folded to a caret, so the stronger color shows instead of the selection's.
        #expect(try await pageScript(webView, "return getSelection().isCollapsed") as? Bool == true)
    }

    /// A tick clicked: the find lands on that match.
    @Test func aTickGoesToItsMatch() async throws {
        let (webView, window) = await page("<p>apple</p><p>apple</p><p>apple</p><p>apple</p>")
        defer { window.close() }
        _ = await PageFind.find("apple", in: webView, backwards: false, showsIndicator: false)
        _ = await FindMarks.mark("apple", in: webView)
        // WebKit counts on from where it was, so its place can be off; the marks say where it landed.
        for target in [2, 0, 3] {
            await FindMarks.moveCaret(toMatch: target, in: webView)
            _ = try #require(await PageFind.find("apple", in: webView, backwards: false, showsIndicator: false))
            #expect(try #require(await FindMarks.mark("apple", in: webView)).current == target)
        }
    }

    /// Ticks follow the matches down a long page, in proportion to its height.
    @Test func marksFollowThePage() async throws {
        let (webView, window) = await page("""
        <style>body { margin: 0 } div { height: 1000px }</style>
        <div>kiwi at the top</div><div>nothing</div><div>kiwi in the middle</div><div>nothing</div><div>kiwi near the end</div>
        """)
        defer { window.close() }
        _ = await PageFind.find("kiwi", in: webView, backwards: false, showsIndicator: false)
        let marked = try #require(await FindMarks.mark("kiwi", in: webView))
        #expect(marked.marks.count == 3)
        #expect(marked.marks == marked.marks.sorted())
        #expect(abs(marked.marks[0] - 0.0) < 0.02)
        #expect(abs(marked.marks[1] - 0.4) < 0.02)
        #expect(abs(marked.marks[2] - 0.8) < 0.02)
        #expect(marked.dark == false)
    }

    /// A page with a great many matches: the first thousand are marked, and the count says there are more.
    @Test func marksStopAtTheCap() async throws {
        let (webView, window) = await page("<p>" + String(repeating: "fig ", count: 1500) + "</p>")
        defer { window.close() }
        let found = try #require(await PageFind.find("fig", in: webView, backwards: false, showsIndicator: false))
        #expect(found.isOverMax)
        let marked = try #require(await FindMarks.mark("fig", in: webView))
        #expect(marked.count == FindMarks.maxMarks + 1)
        #expect(marked.marks.count == FindMarks.maxMarks)
        #expect(marked.current == 0)
    }

    /// Text in an open shadow root and a same-origin frame is marked too; a dark page is said to be dark.
    @Test func shadowRootsFramesAndDarkPages() async throws {
        let (webView, window) = await page("""
        <style>html { background: #111; color: #eee }</style>
        <p>lime</p><div id=host></div><iframe srcdoc="<p>lime and lime</p>" width=300 height=80></iframe>
        <script>document.getElementById('host').attachShadow({ mode: 'open' }).innerHTML = '<p>lime in a shadow</p>';</script>
        """)
        defer { window.close() }
        // The frame loads on its own.
        let end = Date().addingTimeInterval(5)
        while Date() < end, await PageFind.count("lime", in: webView) != 4 { try? await Task.sleep(for: .milliseconds(50)) }
        _ = await PageFind.find("lime", in: webView, backwards: false, showsIndicator: false)
        let marked = try #require(await FindMarks.mark("lime", in: webView))
        #expect(marked.count == 4)
        #expect(marked.dark)
    }

    /// The page changing under the find: the marks are found again by themselves and said to the app.
    @Test func marksFollowThePageChanging() async throws {
        let (webView, window) = await page("<p>plum</p>")
        defer { window.close() }
        FindMarks.install(in: webView)
        _ = await PageFind.find("plum", in: webView, backwards: false, showsIndicator: false)
        #expect(try #require(await FindMarks.mark("plum", in: webView)).count == 1)
        var heard: FindMarks.Snapshot?
        FindMarks.listen(to: webView) { heard = $0 }
        _ = try await pageScript(webView, "document.body.insertAdjacentHTML('beforeend', '<p>another plum</p>')")
        let end = Date().addingTimeInterval(3)
        while Date() < end, heard?.count != 2 { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(heard?.count == 2)
        // Closed: nothing more is heard.
        FindMarks.clear(in: webView)
        heard = nil
        _ = try await pageScript(webView, "document.body.insertAdjacentHTML('beforeend', '<p>plum again</p>')")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(heard == nil)
        #expect(try await webView.runOwnScript("return globalThis.__zigzagFind.state().observers", asFunction: true) as? Int == 0)
    }

    /// Text shown by a class changing, as an accordion or Show more does: the page grows, and the match is marked.
    @Test func marksFollowTextAClassShows() async throws {
        let (webView, window) = await page("""
        <style>.shut { display: none }</style><p>pear</p><div id=more class=shut><p>another pear</p></div>
        """)
        defer { window.close() }
        // On screen (off to the side), so the page is laid out and its size can change.
        window.setFrameOrigin(NSPoint(x: -6000, y: 200))
        window.orderFrontRegardless()
        FindMarks.install(in: webView)
        _ = await PageFind.find("pear", in: webView, backwards: false, showsIndicator: false)
        #expect(try #require(await FindMarks.mark("pear", in: webView)).count == 1)
        var heard: FindMarks.Snapshot?
        FindMarks.listen(to: webView) { heard = $0 }
        _ = try await pageScript(webView, "document.getElementById('more').className = ''")
        let end = Date().addingTimeInterval(4)
        while Date() < end, heard?.count != 2 { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(heard?.count == 2)
        FindMarks.clear(in: webView)
    }

    private func findState(_ webView: WKWebView, _ key: String) async throws -> Any? {
        try await webView.runOwnScript("return globalThis.__zigzagFind.state()[key]", asFunction: true, arguments: ["key": key])
    }

    /// A busy page that only changes classes, or changes text without moving a match, is looked at rarely and says
    /// nothing to the app.
    @Test func aBusyPageIsLookedAtLessAndLessOften() async throws {
        let (webView, window) = await page("""
        <p>plum</p><p id=clock>0</p><div id=box>box</div>
        <script>let n = 0; setInterval(() => { document.getElementById('box').className = 'c' + (n % 2); }, 50);
          setInterval(() => { document.getElementById('clock').firstChild.data = String(++n); }, 100);</script>
        """)
        defer { window.close() }
        FindMarks.install(in: webView)
        _ = await PageFind.find("plum", in: webView, backwards: false, showsIndicator: false)
        #expect(try #require(await FindMarks.mark("plum", in: webView)).count == 1)
        var heard = 0
        FindMarks.listen(to: webView) { _ in heard += 1 }
        try? await Task.sleep(for: .seconds(4))
        // Looked at after a quarter second, then a second, two and three apart: once a second it would be four or more.
        let looks = try #require(try await findState(webView, "looks") as? Int)
        #expect(looks >= 1 && looks <= 3)
        #expect(heard == 0)
        FindMarks.clear(in: webView)
    }

    /// A match the page draws again is marked again within a second or so, even on a busy page (#329).
    @Test func aRedrawnMatchIsMarkedAgainSoon() async throws {
        let (webView, window) = await page("""
        <p id=clock>0</p><div id=list><a href=#>plum</a></div>
        <script>let n = 0; setInterval(() => { document.getElementById('clock').firstChild.data = String(++n); }, 100);</script>
        """)
        defer { window.close() }
        FindMarks.install(in: webView)
        _ = await PageFind.find("plum", in: webView, backwards: false, showsIndicator: false)
        #expect(try #require(await FindMarks.mark("plum", in: webView)).count == 1)
        // Busy long enough to be looked at only every few seconds.
        try? await Task.sleep(for: .seconds(2.5))
        _ = try await pageScript(webView, "document.getElementById('list').innerHTML = '<a href=#>plum</a>'")
        let marked = "return globalThis.__zigzagFind.ranges.length === 1 && !globalThis.__zigzagFind.ranges[0].collapsed"
        let end = Date().addingTimeInterval(1.2)
        var again = false
        while Date() < end, !again {
            again = try await webView.runOwnScript(marked, asFunction: true) as? Bool == true
            if !again { try? await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(again)
        FindMarks.clear(in: webView)
    }

    /// Paused (you're in another window): nothing is watched; back, the page is looked at once and the change heard.
    @Test func pausedMarksCatchUpOnReturn() async throws {
        let (webView, window) = await page("<p>plum</p>")
        defer { window.close() }
        FindMarks.install(in: webView)
        _ = await PageFind.find("plum", in: webView, backwards: false, showsIndicator: false)
        #expect(try #require(await FindMarks.mark("plum", in: webView)).count == 1)
        var heard: FindMarks.Snapshot?
        FindMarks.listen(to: webView) { heard = $0 }
        FindMarks.pause(true, in: webView)
        #expect(try await findState(webView, "observers") as? Int == 0)
        _ = try await pageScript(webView, "document.body.insertAdjacentHTML('beforeend', '<p>another plum</p>')")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(heard == nil)
        FindMarks.pause(false, in: webView)
        let end = Date().addingTimeInterval(3)
        while Date() < end, heard?.count != 2 { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(heard?.count == 2)
        #expect(try await findState(webView, "observers") as? Int == 2)
        // Marked while away: paused from the start.
        _ = await FindMarks.mark("plum", in: webView, paused: true)
        #expect(try await findState(webView, "observers") as? Int == 0)
        FindMarks.clear(in: webView)
    }
}

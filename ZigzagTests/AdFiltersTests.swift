import AppKit
import CryptoKit
import Testing
import WebKit
@testable import Zigzag

/// The community lists' site filters (Web/AdFilters.swift): downloaded, checked and kept, built by Ghostery's engine,
/// and handed to pages of their own site only (#129). The lists and scriptlets here are made up for the tests:
/// uBlock Origin's own are never part of Zigzag or its tests.
@MainActor
@Suite(.serialized)
struct AdFiltersTests {
    // MARK: Made-up lists and scriptlets

    private static func list(_ title: String, _ filters: String, expires: String = "12 hours") -> Data {
        Data(("! Title: \(title)\n! Expires: \(expires)\n" + String(repeating: "! A line the list keeps for its readers.\n", count: 40) + filters + "\n").utf8)
    }

    private static let filters = list("Test filters", """
        www.youtube.com##+js(set-flag, zigzagFlag, yes)
        www.youtube.com##+js(mark-apart)
        www.youtube.com##.ad-box
        """)

    private static let quickFixes = list("Test quick fixes", "example.org##+js(set-flag, zigzagFlag, fixed)")
    private static let unbreak = list("Test unbreak", "example.org#@#+js(set-flag, zigzagFlag, fixed)", expires: "5 days")

    /// Fifty scriptlets, as the engine's resources are shaped: one that sets a value on the page, one that runs apart
    /// from the page's scripts, and others that do nothing.
    private static let scriptlets: Data = {
        var all: [[String: Any]] = [
            ["name": "set-flag.js", "aliases": ["sf.js"], "body": "function setFlag(name, value) { window[name] = value; }", "dependencies": []],
            ["name": "mark-apart.js", "aliases": [], "executionWorld": "ISOLATED",
             "body": "function markApart() { window.zigzagApart = true; document.documentElement.dataset.apart = 'yes'; }", "dependencies": []],
        ]
        for n in 0..<50 { all.append(["name": "nothing-\(n).js", "aliases": [], "body": "function nothing() {}", "dependencies": []]) }
        return try! JSONSerialization.data(withJSONObject: ["scriptlets": all, "redirects": []])
    }()

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: A server that answers as the publishers do

    nonisolated final class Server: URLProtocol, @unchecked Sendable {
        struct Answer { var status: Int; var body: Data; var headers: [String: String] = [:] }
        nonisolated(unsafe) static var answers: [String: Answer] = [:]
        nonisolated(unsafe) static var asked: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.asked.append(request)
            let answer = Self.answers[request.url?.absoluteString ?? ""] ?? Answer(status: 404, body: Data())
            // A copy that's still current: the publisher's validator came back.
            let current = answer.headers["ETag"].map { $0 == request.value(forHTTPHeaderField: "If-None-Match") } ?? false
            let response = HTTPURLResponse(url: request.url!, statusCode: current ? 304 : answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !current { client?.urlProtocol(self, didLoad: answer.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private static func serveEverything() {
        let revision = sha256(scriptlets)
        Server.asked = []
        Server.answers = [
            AdFilterSources.lists[0].urls[0].absoluteString: .init(status: 200, body: filters, headers: ["ETag": "\"f1\""]),
            AdFilterSources.lists[1].urls[0].absoluteString: .init(status: 200, body: quickFixes, headers: ["ETag": "\"q1\""]),
            AdFilterSources.lists[2].urls[0].absoluteString: .init(status: 200, body: unbreak, headers: ["Last-Modified": "Wed, 11 Nov 2026 12:00:00 GMT"]),
            AdFilterSources.scriptletsIndex.absoluteString: .init(status: 200, body: Data(#"{"name":"test","revisions":["\#(revision)"]}"#.utf8), headers: ["ETag": "\"i1\""]),
            AdFilterSources.scriptlets(revision: revision).absoluteString: .init(status: 200, body: scriptlets),
        ]
    }

    private func makeEngine() -> (AdEngine, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdFiltersTests-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Server.self]
        return (AdEngine(directory: directory, session: URLSession(configuration: configuration)), directory)
    }

    private func waitUntilReady(_ engine: AdEngine, generation: Int = 1) async throws {
        for _ in 0..<200 where engine.status.generation < generation { try await Task.sleep(for: .milliseconds(50)) }
        #expect(engine.status.ready)
        #expect(engine.status.generation >= generation)
    }

    // MARK: Checking what comes down

    @Test func aListIsTextThatStartsWithItsTitle() {
        #expect(AdFilterSources.isList(Self.filters))
        #expect(!AdFilterSources.isList(Data("<!doctype html><title>Rate limited</title>".utf8)))
        #expect(!AdFilterSources.isList(Data("! Title: cut short".utf8)))
        #expect(!AdFilterSources.isList(Data(repeating: 0xff, count: 4_000)))
    }

    @Test func aListStaysFreshAsLongAsItSaysWithinLimits() {
        #expect(AdFilterSources.lifetime(of: Self.list("x", "", expires: "12 hours")) == 12 * 3_600)
        #expect(AdFilterSources.lifetime(of: Self.list("x", "", expires: "5 days")) == 86_400)
        #expect(AdFilterSources.lifetime(of: Self.list("x", "", expires: "1 hours")) == 6 * 3_600)
        #expect(AdFilterSources.lifetime(of: Data("! Title: no expiry\n".utf8)) == 86_400)
    }

    @Test func scriptletsMustBeTheRevisionAskedFor() throws {
        let revision = Self.sha256(Self.scriptlets)
        #expect(AdFilterSources.latestRevision(in: Data(#"{"revisions":["\#(String(repeating: "0", count: 64))","\#(revision)"]}"#.utf8)) == revision)
        #expect(AdFilterSources.latestRevision(in: Data(#"{"revisions":["../../etc"]}"#.utf8)) == nil)
        #expect(AdFilterSources.isScriptlets(Self.scriptlets, revision: revision))
        var changed = Self.scriptlets
        changed.append(contentsOf: Data(" ".utf8))
        #expect(!AdFilterSources.isScriptlets(changed, revision: revision))
        let few = try JSONSerialization.data(withJSONObject: ["scriptlets": [["name": "a.js", "aliases": [], "body": "function a() {}", "dependencies": []]]])
        #expect(!AdFilterSources.isScriptlets(few, revision: Self.sha256(few)))
    }

    // MARK: Downloading and building

    @Test func theListsAreDownloadedBuiltAndMatchedBySite() async throws {
        Self.serveEverything()
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start()
        try await waitUntilReady(engine)
        #expect(engine.status.scriptlets == 52)

        let youTube = await engine.injection(for: URL(string: "https://www.youtube.com/watch?v=x")!)
        #expect(youTube.page.count == 1)
        #expect(youTube.page.first?.contains("zigzagFlag") == true)
        #expect(youTube.isolated.count == 1)
        #expect(youTube.styles.contains(".ad-box"))
        // The unbreak list's exception wins over quick fixes' filter.
        #expect(await engine.injection(for: URL(string: "https://example.org/")!).isEmpty)
        #expect(await engine.injection(for: URL(string: "https://example.com/")!).isEmpty)

        // Built once: the next launch takes the saved engine, without building again.
        let again = AdEngine(directory: directory, session: URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Server.self]; return c }()))
        again.start()
        try await waitUntilReady(again)
        #expect(again.status.builtIn == 0)
        #expect(await again.injection(for: URL(string: "https://www.youtube.com/")!).page.count == 1)
    }

    /// The next look sends each list's validator back and keeps what it has when nothing changed.
    @Test func anUnchangedListIsNotDownloadedAgain() async throws {
        Self.serveEverything()
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await engine.update())
        Server.asked = []
        #expect(await engine.update(force: true) == false)
        let first = try #require(Server.asked.first { $0.url == AdFilterSources.lists[0].urls[0] })
        #expect(first.value(forHTTPHeaderField: "If-None-Match") == "\"f1\"")
        let unbreak = try #require(Server.asked.first { $0.url == AdFilterSources.lists[2].urls[0] })
        #expect(unbreak.value(forHTTPHeaderField: "If-Modified-Since") == "Wed, 11 Nov 2026 12:00:00 GMT")
        // The scriptlets' index is current, so the scriptlets themselves aren't asked for.
        #expect(!Server.asked.contains { $0.url?.absoluteString.hasSuffix("list.txt") == true })
        // Not expired: nothing is asked at all.
        Server.asked = []
        #expect(await engine.update() == false)
        #expect(Server.asked.isEmpty)
    }

    /// A publisher answering with an error page, or scriptlets that aren't what they say, leaves the last good copy.
    @Test func aBadDownloadKeepsTheLastGoodCopy() async throws {
        Self.serveEverything()
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await engine.update())
        let saved = try Data(contentsOf: directory.appendingPathComponent("ublock-filters.txt"))
        let first = AdFilterSources.lists[0].urls[0].absoluteString
        Server.answers[first] = .init(status: 200, body: Data("<html>Too many requests</html>".utf8))
        let revision = String(repeating: "a", count: 64)
        Server.answers[AdFilterSources.scriptletsIndex.absoluteString] = .init(status: 200, body: Data(#"{"revisions":["\#(revision)"]}"#.utf8))
        Server.answers[AdFilterSources.scriptlets(revision: revision).absoluteString] = .init(status: 200, body: Self.scriptlets)
        // The mirror after it has the list.
        Server.answers[AdFilterSources.lists[0].urls[1].absoluteString] = .init(status: 200, body: Self.filters)
        #expect(await engine.update(force: true) == false)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ublock-filters.txt")) == saved)
        #expect(try Data(contentsOf: directory.appendingPathComponent("scriptlets.json")) == Self.scriptlets)
        #expect(Server.asked.contains { $0.url == AdFilterSources.lists[0].urls[1] })
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    private func load(_ webView: WKWebView, at address: String) async {
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString("<html><body><div class='ad-box'>Ad</div></body></html>", baseURL: URL(string: address))
        }
        withExtendedLifetime(loading) {}
    }

    @Test func aPageGetsItsOwnSitesFiltersOnly() async throws {
        Self.serveEverything()
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start()
        try await waitUntilReady(engine)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        let other = WKUserScript(source: "window.other = 1", injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(other)
        let youTube = URL(string: "https://www.youtube.com/watch?v=x")!
        await PageFilters.prepare(controller, for: youTube, mainFrame: true, wanted: true, engine: engine)
        await PageFilters.prepare(controller, for: youTube, mainFrame: true, wanted: true, engine: engine)
        #expect(controller.userScripts.filter(PageFilters.isOurs).count == 3)
        #expect(PageFilters.hosts(in: controller) == ["www.youtube.com"])

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        await load(webView, at: "https://www.youtube.com/watch?v=x")
        #expect(try await webView.callAsyncJavaScript("return window.zigzagFlag", contentWorld: .page) as? String == "yes")
        // The scriptlet that keeps apart ran apart: the page sees what it did to the page, not its variables.
        #expect(try await webView.callAsyncJavaScript("return document.documentElement.dataset.apart", contentWorld: .page) as? String == "yes")
        #expect(try await webView.callAsyncJavaScript("return window.zigzagApart === undefined", contentWorld: .page) as? Bool == true)
        #expect(try await webView.callAsyncJavaScript("return getComputedStyle(document.querySelector('.ad-box')).display", contentWorld: .page) as? String == "none")

        // Another site in the same web view runs none of them.
        await load(webView, at: "https://example.com/")
        #expect(try await webView.callAsyncJavaScript("return window.zigzagFlag === undefined && document.documentElement.dataset.apart === undefined",
                                                      contentWorld: .page) as? Bool == true)
        #expect(try await webView.callAsyncJavaScript("return getComputedStyle(document.querySelector('.ad-box')).display", contentWorld: .page) as? String == "block")

        // A frame from another host joins the page's; another page takes the place of the page before it.
        let nocookie = URL(string: "https://www.youtube-nocookie.com/embed/x")!
        await PageFilters.prepare(controller, for: nocookie, mainFrame: false, wanted: true, engine: engine)
        #expect(PageFilters.hosts(in: controller) == ["www.youtube.com", "www.youtube-nocookie.com"])
        await PageFilters.prepare(controller, for: URL(string: "https://example.com/")!, mainFrame: true, wanted: true, engine: engine)
        #expect(PageFilters.hosts(in: controller) == ["example.com"])
        #expect(controller.userScripts.filter(PageFilters.isOurs).isEmpty)
        await PageFilters.prepare(controller, for: youTube, mainFrame: true, wanted: true, engine: engine)
        #expect(controller.userScripts.filter(PageFilters.isOurs).count == 3)

        // Not wanted (blocking off, the site allowed): only Zigzag's filters go.
        await PageFilters.prepare(controller, for: youTube, mainFrame: true, wanted: false, engine: engine)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first === other)
        #expect(PageFilters.hosts(in: controller).isEmpty)
    }

    /// A private window's web view, which no profile's store matches, keeps Zigzag's filters: it runs no extensions.
    @Test func aPrivatePageKeepsZigzagsFilters() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #expect(ContentBlocker.extensionBlocker(for: webView) == nil)
    }

    // MARK: Stepping aside for an ad blocker extension

    @Test func knownAdBlockersAreFoundByTheirStoreIDs() {
        #expect(AdBlockers.active(among: ["ddkjiahejlhfcafbddmgiahcphecmpfh"]) == "uBlock Origin Lite")
        #expect(AdBlockers.active(among: ["cjpalhdlnbpafiamejdnhcphjbkeiagm"]) == "uBlock Origin")
        #expect(AdBlockers.active(among: ["bgnkhhnnamicmpeenaelnjfhikgbkllg"]) == "AdGuard")
        #expect(AdBlockers.active(among: ["gighmmpiobklfepjocnamgkkbiglidom"]) == "AdBlock")
        #expect(AdBlockers.active(among: ["cfhdojbkjhnklbpkdaibdccddilifddb"]) == "Adblock Plus")
        #expect(AdBlockers.active(among: ["mlomiejdfkolichcflejclcbmpeaniij"]) == "Ghostery")
        // Not an ad blocker (1Password), or none at all: Zigzag's filters run.
        #expect(AdBlockers.active(among: ["aeblfdkhhhdcdjpifhhbdiojplfjncoa"]) == nil)
        #expect(AdBlockers.active(among: []) == nil)
        // Several: the same one every time.
        #expect(AdBlockers.active(among: ["mlomiejdfkolichcflejclcbmpeaniij", "ddkjiahejlhfcafbddmgiahcphecmpfh"]) == "Ghostery")
        #expect(AdBlockers.active(among: ["ddkjiahejlhfcafbddmgiahcphecmpfh", "mlomiejdfkolichcflejclcbmpeaniij"]) == "Ghostery")
    }

    /// Only an ad blocker that may run on YouTube takes over: one kept off YouTube leaves it to Zigzag.
    @Test func anAdBlockerStepsInOnlyWhereItRunsOnYouTube() {
        #expect(AdBlockers.reachesYouTube(access: .all, approved: nil, sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .all, approved: ["<all_urls>"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .all, approved: ["*://*/*"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .all, approved: ["https://*.youtube.com/*"], sites: [], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .all, approved: [], sites: [], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .all, approved: ["https://github.com/*", "http://*/*"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .sites, approved: ["<all_urls>"], sites: ["youtube.com"], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .sites, approved: ["<all_urls>"], sites: ["github.com"], offSites: []))
        #expect(!AdBlockers.reachesYouTube(access: .click, approved: ["<all_urls>"], sites: [], offSites: []))
        #expect(AdBlockers.reachesYouTube(access: .click, approved: ["<all_urls>"], sites: ["youtube.com"], offSites: []))
        // Extensions off on YouTube.
        #expect(!AdBlockers.reachesYouTube(access: .all, approved: ["<all_urls>"], sites: [], offSites: ["youtube.com"]))
    }
}

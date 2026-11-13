import AppKit
import CryptoKit
import JavaScriptCore
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

    /// Zigzag's own list as the website might serve it, in place of the one in the app.
    private static let zigzagFixes = list("Test Zigzag fixes", "example.net##+js(set-flag, zigzagFlag, ours)")

    /// Fifty scriptlets, as the engine's resources are shaped: one that sets a value on the page, one that runs apart
    /// from the page's scripts, two that note what they were asked to stop under the names of uBlock Origin's, and
    /// others that do nothing.
    private static let scriptlets: Data = {
        var all: [[String: Any]] = [
            ["name": "set-flag.js", "aliases": ["sf.js"], "body": "function setFlag(name, value) { window[name] = value; }", "dependencies": []],
            ["name": "mark-apart.js", "aliases": [], "executionWorld": "ISOLATED",
             "body": "function markApart() { window.zigzagApart = true; document.documentElement.dataset.apart = 'yes'; }", "dependencies": []],
            ["name": "prevent-fetch.js", "aliases": [], "body": "function preventFetch(url) { (window.zigzagStopped ||= []).push('fetch ' + url); }", "dependencies": []],
            ["name": "prevent-xhr.js", "aliases": [], "body": "function preventXhr(url) { (window.zigzagStopped ||= []).push('xhr ' + url); }", "dependencies": []],
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

    /// The scriptlet revisions the engines here take, as a release pins its own.
    nonisolated(unsafe) static var pinned: [String] = []

    private static func serveEverything(scriptlets: Data = scriptlets, filters: Data = filters) {
        let revision = sha256(scriptlets)
        pinned = [revision]
        Server.asked = []
        Server.answers = [
            AdFilterSources.zigzagFixes.urls[0].absoluteString: .init(status: 200, body: zigzagFixes, headers: ["ETag": "\"z1\""]),
            AdFilterSources.lists[0].urls[0].absoluteString: .init(status: 200, body: filters, headers: ["ETag": "\"f1\""]),
            AdFilterSources.lists[1].urls[0].absoluteString: .init(status: 200, body: quickFixes, headers: ["ETag": "\"q1\""]),
            AdFilterSources.lists[2].urls[0].absoluteString: .init(status: 200, body: unbreak, headers: ["Last-Modified": "Wed, 11 Nov 2026 12:00:00 GMT"]),
            AdFilterSources.scriptlets(revision: revision).absoluteString: .init(status: 200, body: scriptlets),
        ]
    }

    private func makeEngine() -> (AdEngine, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdFiltersTests-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Server.self]
        return (AdEngine(directory: directory, session: URLSession(configuration: configuration), pinnedRevisions: Self.pinned), directory)
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
        #expect(engine.status.scriptlets == 54)

        let youTube = await engine.injection(for: URL(string: "https://www.youtube.com/watch?v=x")!)
        #expect(youTube.page.count == 1)
        #expect(youTube.page.first?.contains("zigzagFlag") == true)
        #expect(youTube.isolated.count == 1)
        #expect(youTube.styles.contains(".ad-box"))
        // The unbreak list's exception wins over quick fixes' filter.
        #expect(await engine.injection(for: URL(string: "https://example.org/")!).isEmpty)
        #expect(await engine.injection(for: URL(string: "https://example.com/")!).isEmpty)

        // Built once: the next launch takes the saved engine, without building again.
        let again = AdEngine(directory: directory, session: URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Server.self]; return c }()), pinnedRevisions: Self.pinned)
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
        // The pinned scriptlets are here, and a revision never changes: they aren't asked for again.
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
        // The mirror after it has the list.
        Server.answers[AdFilterSources.lists[0].urls[1].absoluteString] = .init(status: 200, body: Self.filters)
        #expect(await engine.update(force: true) == false)
        #expect(try Data(contentsOf: directory.appendingPathComponent("ublock-filters.txt")) == saved)
        #expect(try Data(contentsOf: directory.appendingPathComponent("scriptlets.json")) == Self.scriptlets)
        #expect(Server.asked.contains { $0.url == AdFilterSources.lists[0].urls[1] })
    }

    /// The scriptlets are the code that runs in pages: only a revision the release pinned is ever used, whatever the
    /// CDN serves, and without one the lists run with no scriptlets.
    @Test func onlyPinnedScriptletsRun() async throws {
        Self.serveEverything()
        let pin = Self.pinned[0]
        // The CDN, or someone in between, serves something else at the pinned address.
        var changed = Self.scriptlets
        changed.append(contentsOf: Data(" ".utf8))
        Server.answers[AdFilterSources.scriptlets(revision: pin).absoluteString] = .init(status: 200, body: changed)
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A copy already on disk that isn't pinned (left from before, or changed there) isn't used either.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try changed.write(to: directory.appendingPathComponent("scriptlets.json"))
        engine.start()
        try await waitUntilReady(engine)
        #expect(engine.status.scriptlets == 0)
        let youTube = await engine.injection(for: URL(string: "https://www.youtube.com/watch?v=x")!)
        #expect(youTube.page.isEmpty && youTube.isolated.isEmpty)
        // The lists still hide what they name.
        #expect(youTube.styles.contains(".ad-box"))
        // The pinned revision, once it comes, is taken.
        Server.answers[AdFilterSources.scriptlets(revision: pin).absoluteString] = .init(status: 200, body: Self.scriptlets)
        #expect(await engine.update(force: true))
        #expect(try Data(contentsOf: directory.appendingPathComponent("scriptlets.json")) == Self.scriptlets)
    }

    /// A list names a scriptlet and hands it strings, nothing more: an argument that tries to close the scriptlet's
    /// string and go on with code of its own stays a string.
    @Test func aFiltersArgumentsStayStrings() async throws {
        let sneaky = Self.list("Test sneaky", #"""
            www.youtube.com##+js(set-flag, zigzagFlag, a`);window.zigzagRan=1;(`)
            example.org##+js(set-flag, zigzagFlag, $'$`$&)
            example.net##+js(set-flag, zigzagFlag, ${window.zigzagRan=2})
            """#)
        Self.serveEverything(filters: sneaky)
        Server.answers[AdFilterSources.lists[1].urls[0].absoluteString] = .init(status: 200, body: Self.list("Test quick fixes", ""))
        Server.answers[AdFilterSources.lists[2].urls[0].absoluteString] = .init(status: 200, body: Self.list("Test unbreak", ""))
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start()
        try await waitUntilReady(engine)
        let expected = ["https://www.youtube.com/": "a`);window.zigzagRan=1;(`", "https://example.org/": "$'$`$&", "https://example.net/": "${window.zigzagRan=2}"]
        for (address, value) in expected {
            let script = try #require(await engine.injection(for: URL(string: address)!).page.first, "\(address)")
            let context = try #require(JSContext())
            context.evaluateScript("var window = globalThis;")
            context.evaluateScript(script)
            #expect(context.exception == nil, "\(address)")
            #expect(context.evaluateScript("window.zigzagRan === undefined").toBool(), "\(address)")
            #expect(context.evaluateScript("window.zigzagFlag").toString() == value, "\(address)")
        }
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

    // MARK: Zigzag's own fixes

    @Test func zigzagsOwnListIsInTheAppAndReadsAsAList() throws {
        let data = try #require(AdFilterSources.zigzagFixes.bundledData)
        #expect(AdFilterSources.isList(data, minimumSize: AdFilterSources.zigzagFixes.minimumSize))
        #expect(AdFilterSources.lifetime(of: data) == 12 * 3_600)
        let text = String(decoding: data, as: UTF8.self)
        // DeepSeek's telemetry, which EasyPrivacy blocks (#208).
        #expect(text.contains("\nchat.deepseek.com##+js(prevent-fetch, /api/v0/telemetry)\n"))
        #expect(text.contains("\nchat.deepseek.com##+js(prevent-xhr, /api/v0/telemetry)\n"))
        // Every filter is for a site it names: nothing in it reaches every site.
        for line in text.split(separator: "\n") where !line.hasPrefix("!") {
            #expect(!line.hasPrefix("#") && line.contains("#"), "\(line)")
        }
        // A cut-off copy, or an error page, isn't taken for it.
        #expect(!AdFilterSources.isList(Data("! Title: Zigzag fixes\n".utf8), minimumSize: AdFilterSources.zigzagFixes.minimumSize))
        #expect(!AdFilterSources.isList(Data(("<html>" + String(repeating: "Not found. ", count: 40)).utf8), minimumSize: AdFilterSources.zigzagFixes.minimumSize))
    }

    /// Offline, or before the website answers, the copy in the app is the one in use, for its own sites only; the
    /// website's copy takes its place once it comes.
    @Test func theCopyInTheAppIsUsedUntilTheWebsitesComes() async throws {
        Self.serveEverything()
        let website = AdFilterSources.zigzagFixes.urls[0].absoluteString
        Server.answers[website] = nil
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start()
        try await waitUntilReady(engine)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("zigzag-fixes.txt").path))

        let deepSeek = URL(string: "https://chat.deepseek.com/a/chat/s/x")!
        let fixes = await engine.injection(for: deepSeek)
        #expect(fixes.page.count == 2)
        #expect(fixes.page.contains { $0.contains("preventFetch") && $0.contains("/api/v0/telemetry") })
        #expect(fixes.page.contains { $0.contains("preventXhr") && $0.contains("/api/v0/telemetry") })
        #expect(fixes.isolated.isEmpty && fixes.styles.isEmpty)
        #expect(await engine.injection(for: URL(string: "https://deepseek.com/")!).isEmpty)
        #expect(await engine.injection(for: URL(string: "https://example.com/")!).isEmpty)

        // The website answers: its copy is downloaded, and the engine built from it next has it in place of the app's.
        Server.answers[website] = .init(status: 200, body: Self.zigzagFixes)
        #expect(await engine.update())
        #expect(try Data(contentsOf: directory.appendingPathComponent("zigzag-fixes.txt")) == Self.zigzagFixes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Server.self]
        let again = AdEngine(directory: directory, session: URLSession(configuration: configuration), pinnedRevisions: Self.pinned)
        again.start()
        try await waitUntilReady(again)
        #expect(await again.injection(for: deepSeek).isEmpty)
        #expect(await again.injection(for: URL(string: "https://example.net/")!).page.first?.contains("ours") == true)
    }

    /// uBlock Origin's own scriptlets (GPL-3.0) are kept out of the repository, so the test that runs Zigzag's list
    /// with them runs only where a copy is in Fixtures: `ublock-scriptlets.json`, as the app keeps it in
    /// Ad Filters/scriptlets.json.
    nonisolated static var realScriptlets: URL? {
        Bundle(for: AdFiltersFixtureMarker.self).url(forResource: "ublock-scriptlets", withExtension: "json")
    }

    /// The content blocker's rule for DeepSeek's telemetry, as EasyPrivacy has it, and one for a call that isn't it.
    private static let telemetryRules = """
    [{"trigger": {"url-filter": "\\\\/api\\\\/v0\\\\/telemetry"}, "action": {"type": "block"}},
     {"trigger": {"url-filter": "\\\\/api\\\\/v0\\\\/blocked-call"}, "action": {"type": "block"}}]
    """

    /// DeepSeek's own flush, as its telemetry sends it: a keepalive POST to the blocked address, read as a network
    /// failure when nothing comes back. Then the same by XMLHttpRequest.
    private static let telemetry = """
    const sent = await fetch('/api/v0/telemetry', { method: 'POST', body: new Uint8Array([1, 2, 3]), keepalive: true,
                                                     headers: { 'Content-Type': 'application/octet-stream' } })
      .then((response) => response.status, () => 'failed');
    const posted = await new Promise((done) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/api/v0/telemetry');
      xhr.onload = () => done(xhr.readyState + ' ' + xhr.status);
      xhr.onerror = () => done('failed');
      xhr.send('x');
    });
    return sent + ' ' + posted;
    """

    /// DeepSeek told you to check your browser extensions when its blocked telemetry kept failing (#208). With the
    /// list's scriptlets, its fetch and XMLHttpRequest get an empty answer before the content blocker sees a request.
    @Test(.enabled(if: realScriptlets != nil)) func deepSeeksBlockedTelemetryGetsAnAnswer() async throws {
        Self.serveEverything(scriptlets: try Data(contentsOf: try #require(Self.realScriptlets)))
        Server.answers[AdFilterSources.zigzagFixes.urls[0].absoluteString] = nil
        let (engine, directory) = makeEngine()
        defer { try? FileManager.default.removeItem(at: directory) }
        engine.start()
        try await waitUntilReady(engine)

        func page(at address: String, filters: Bool = true) async throws -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let rules = try #require(try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "zigzag-test-fixes-\(UUID().uuidString)", encodedContentRuleList: Self.telemetryRules))
            configuration.userContentController.add(rules)
            await PageFilters.prepare(configuration.userContentController, for: URL(string: address)!, mainFrame: true, wanted: filters, engine: engine)
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            await load(webView, at: address)
            return webView
        }
        func run(_ body: String, in webView: WKWebView) async throws -> String? {
            try await webView.callAsyncJavaScript(body, contentWorld: .page).map { String(describing: $0) }
        }

        let deepSeek = try await page(at: "https://chat.deepseek.com/")
        #expect(try await run(Self.telemetry, in: deepSeek) == "200 4 200")
        // On DeepSeek, a blocked address that isn't its telemetry stays blocked.
        let call = "return await fetch('/api/v0/blocked-call').then((response) => String(response.status), () => 'failed')"
        #expect(try await run(call, in: deepSeek) == "failed")
        // Without the site filters (blocking off for the scriptlets, an ad blocker extension) it fails as before.
        #expect(try await run(Self.telemetry, in: try await page(at: "https://chat.deepseek.com/", filters: false)) == "failed failed")
        // Another site's own telemetry stays blocked, and its fetch stays the browser's.
        let other = try await page(at: "https://example.com/")
        #expect(try await run(Self.telemetry, in: other) == "failed failed")
        #expect(try await run("return String(fetch.toString().includes('[native code]'))", in: other) == "true")
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

/// Finds the test bundle, for the fixtures only some Macs have.
private final class AdFiltersFixtureMarker {}

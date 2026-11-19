import Foundation
import Network
import Testing
import WebKit
import os
@testable import Zigzag

/// What the extension bridge reads from history for `chrome.history`, and how it shapes values for the extension.
@MainActor
struct ExtensionBridgeTests {
    private func store() -> HistoryStore {
        let store = HistoryStore(path: ":memory:")
        let now = Date()
        store.recordVisit(url: URL(string: "https://en.wikipedia.org/wiki/Bauhaus")!, title: "Bauhaus", at: now.addingTimeInterval(-60))
        store.recordVisit(url: URL(string: "https://example.com/old")!, title: "Old page", at: now.addingTimeInterval(-10 * 86_400))
        store.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub", at: now)
        return store
    }

    @Test func searchesByTextAndTimeNewestFirst() {
        let history = store()
        #expect(history.items(matching: "", from: nil, to: nil, limit: 10).map(\.entry.title) == ["GitHub", "Bauhaus", "Old page"])
        #expect(history.items(matching: "bauhaus wiki", from: nil, to: nil, limit: 10).map(\.entry.title) == ["Bauhaus"])
        #expect(history.items(matching: "", from: Date(timeIntervalSinceNow: -86_400), to: nil, limit: 10).count == 2)
        #expect(history.items(matching: "", from: nil, to: nil, limit: 1).count == 1)
        // Text that would mean something to SQL is only text.
        #expect(history.items(matching: "%", from: nil, to: nil, limit: 10).isEmpty)
    }

    @Test func idsAreStableAndFindTheirPage() {
        let history = store()
        let url = URL(string: "https://github.com/")!
        let first = history.items(matching: "github", from: nil, to: nil, limit: 1).first
        #expect(first?.id == history.item(for: url)?.id)
    }

    @Test func removesARangeAndSaysWhatWent() {
        let history = store()
        var removed: [URL]?
        history.onRemove = { removed = $0 }
        _ = history.remove(from: Date(timeIntervalSinceNow: -20 * 86_400), to: Date(timeIntervalSinceNow: -86_400))
        #expect(removed == [URL(string: "https://example.com/old")!])
        #expect(history.items(matching: "", from: nil, to: nil, limit: 10).count == 2)
    }

    @Test func valuesCrossAsJSON() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let plain = try #require(ExtensionBridge.plain(["when": date, "count": 3, "none": nil, "list": [date]] as [String: Any?]) as? [String: Any])
        #expect(plain["when"] as? Double == 1_700_000_000_000)
        #expect(plain["count"] as? Int == 3)
        #expect(plain["none"] == nil)
        #expect((plain["list"] as? [Any])?.first as? Double == 1_700_000_000_000)
        #expect(JSONSerialization.isValidJSONObject(plain))
    }
}

extension ExtensionBridgeTests {
    @Test func credentialedFetchUsesEachExtensionsCurrentHostAccess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","host_permissions":["https://api.example/*","https://accounts.example/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let first = WKWebExtensionContext(for: ext), second = WKWebExtensionContext(for: ext)
        first.uniqueIdentifier = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        second.uniqueIdentifier = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let api = try WKWebExtension.MatchPattern(string: "https://api.example/*")
        let accounts = try WKWebExtension.MatchPattern(string: "https://accounts.example/*")
        first.setPermissionStatus(.grantedExplicitly, for: api)
        second.setPermissionStatus(.grantedExplicitly, for: accounts)
        // Fetch may send cookies with host access; it does not require permission to inspect cookies.
        #expect(!first.hasPermission(.cookies))
        for path in ["/session", "/api/profile?refresh=true", "/arbitrary/path"] {
            let url = URL(string: "https://api.example\(path)")!
            #expect(BridgeExtensionFetch.allows(url, context: first))
            #expect(!BridgeExtensionFetch.allows(url, context: second))
        }
        #expect(BridgeExtensionFetch.allows(URL(string: "https://accounts.example/me")!, context: second))
        for text in ["https://unapproved.example/me", "https://api.example.evil.test/me", "http://api.example/me",
                     "file:///etc/passwd", "https://user:synthetic@api.example/me"] {
            #expect(!BridgeExtensionFetch.allows(URL(string: text)!, context: first))
        }
        first.setPermissionStatus(.deniedExplicitly, for: api)
        #expect(!BridgeExtensionFetch.allows(URL(string: "https://api.example/session")!, context: first))
        // A site granted by site access that the manifest never asked for (Zigzag's "When you click it").
        let clicked = try WKWebExtension.MatchPattern(string: "*://clicked.example/*")
        second.setPermissionStatus(.grantedExplicitly, for: clicked)
        #expect(second.hasAccess(to: URL(string: "https://clicked.example/me")!))
        #expect(!BridgeExtensionFetch.allows(URL(string: "https://clicked.example/me")!, context: second))
    }

    /// Optional host permissions count once granted at runtime, and "<all_urls>" reaches every site, as in Chrome.
    @Test func credentialedFetchFollowsOptionalAndAllSitesGrants() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","optional_host_permissions":["https://later.example/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let url = URL(string: "https://later.example/me")!
        #expect(!BridgeExtensionFetch.allows(url, context: context))
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://later.example/*"))
        #expect(BridgeExtensionFetch.allows(url, context: context))

        let everywhere = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: everywhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: everywhere) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","host_permissions":["<all_urls>"]}"#.utf8)
            .write(to: everywhere.appendingPathComponent("manifest.json"))
        let all = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: everywhere))
        #expect(!BridgeExtensionFetch.allows(url, context: all))
        all.setPermissionStatus(.grantedExplicitly, for: .allURLs())
        #expect(BridgeExtensionFetch.allows(url, context: all))
    }

    @Test(arguments: ["Lax", "Strict"])
    func credentialedFetchUsesItsCookieStoreAndKeepsRefreshes(sameSite: String) async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let store = WKWebsiteDataStore.nonPersistent()
        let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "synthetic", .domain: "127.0.0.1", .path: "/",
                                                         .init("SameSite"): sameSite, .init("HttpOnly"): "TRUE"]))
        await store.httpCookieStore.setCookie(cookie)
        let bridge = ExtensionFetchRequests()
        let response = try #require(try await bridge.response([:], url: url, extensionID: "test", store: store) as? [String: Any])
        #expect(response["status"] as? Int == 200)
        let body = try #require(response["body"] as? String)
        let bytes = try #require(Data(base64Encoded: body))
        #expect(String(decoding: bytes, as: UTF8.self).contains("\"signedIn\":true"))
        #expect(await store.httpCookieStore.allCookies().contains { $0.name == "refreshed" && $0.value == "synthetic" && $0.isHTTPOnly })
        // Honor a client's no-store even when an earlier response was cacheable.
        _ = try await bridge.response(["cache": "no-store"], url: url, extensionID: "test", store: store)
        let separate = try #require(try await bridge.response([:], url: url, extensionID: "test", store: .nonPersistent()) as? [String: Any])
        let separateBody = try #require(separate["body"] as? String)
        let separateBytes = try #require(Data(base64Encoded: separateBody))
        #expect(String(decoding: separateBytes, as: UTF8.self).contains("\"signedIn\":false"))
        #expect(server.requests.withLock { $0 } == 3)
    }

    @Test func accountCancellationAndRevokedAccessPreventDispatch() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let bridge = ExtensionFetchRequests()
        let id = UUID()
        bridge.cancel(id, extensionID: "test")
        await #expect(throws: BridgeError.self) {
            try await bridge.response([:], url: url, extensionID: "test", store: .nonPersistent(), requestID: id)
        }
        await #expect(throws: BridgeError.self) {
            try await bridge.response([:], url: url, extensionID: "test", store: .nonPersistent(), authorize: { false })
        }
        let duringSetup = UUID()
        await #expect(throws: BridgeError.self) {
            try await bridge.response([:], url: url, extensionID: "test", store: .nonPersistent(), requestID: duringSetup) {
                bridge.cancel(duringSetup, extensionID: "test")
                return true
            }
        }
        #expect(server.requests.withLock { $0 } == 0)
    }

    @Test func cancellationBelongsToItsExtensionAndIsClearedOnUnload() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let bridge = ExtensionFetchRequests(), id = UUID()
        bridge.cancel(id, extensionID: "first")
        // The same request ID in a different extension is a different request.
        _ = try await bridge.response([:], url: url, extensionID: "second", store: .nonPersistent(), requestID: id)
        bridge.release("first")
        _ = try await bridge.response([:], url: url, extensionID: "first", store: .nonPersistent(), requestID: id)
        #expect(server.requests.withLock { $0 } == 2)
    }

    @Test func sameExtensionRequestsKeepEachProfilesCookiesAndCancellation() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let first = ExtensionFetchRequests(), second = ExtensionFetchRequests()
        let firstStore = WKWebsiteDataStore.nonPersistent(), secondStore = WKWebsiteDataStore.nonPersistent()
        let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "synthetic", .domain: "127.0.0.1", .path: "/",
                                                         .init("SameSite"): "Lax", .init("HttpOnly"): "TRUE"]))
        await firstStore.httpCookieStore.setCookie(cookie)
        // Each profile's bridge owns its request manager, even for the same installed extension and request ID.
        let id = UUID()
        first.cancel(id, extensionID: "same-extension")
        let separate = try await second.response([:], url: url, extensionID: "same-extension", store: secondStore, requestID: id)
        await #expect(throws: BridgeError.self) {
            try await first.response([:], url: url, extensionID: "same-extension", store: firstStore, requestID: id)
        }
        let signedIn = try await first.response([:], url: url, extensionID: "same-extension", store: firstStore, requestID: id)
        for (response, expected) in [(separate, false), (signedIn, true)] {
            let value = try #require(response as? [String: Any])
            let body = try #require(value["body"] as? String)
            let bytes = try #require(Data(base64Encoded: body))
            #expect(String(decoding: bytes, as: UTF8.self).contains("\"signedIn\":\(expected)"))
        }
        #expect(server.requests.withLock { $0 } == 2)
    }

    @Test(arguments: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
    func credentialedFetchIsSharedAndLeavesUnsupportedRequestsUntouched(extensionID: String) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        let result = try await page.callAsyncJavaScript("""
            const calls = [], normal = [];
            let hold = false;
            // Unlike extension pages, the initial about:blank test page isn't a secure context.
            if (!crypto.randomUUID) crypto.randomUUID = () => '00000000-0000-4000-8000-000000000000';
            globalThis.chrome = { runtime: {
              id: extensionID, getManifest: () => ({}),
              sendNativeMessage: async (host, message) => {
                calls.push(message);
                const options = message.args[0];
                if (message.fn === 'cancel') return { value: null };
                if (options.url.includes('unapproved.example')) return { value: { fallback: true } };
                if (options.url.includes('fails.example')) return { error: 'Synthetic network failure' };
                if (hold) return await new Promise(() => {});
                return { value: { status: 200, statusText: 'OK', headers: [], body: 'AP+AQQ==', url: options.url, redirected: false } };
              }
            } };
            globalThis.fetch = async (input, init) => { normal.push([input, init]); return new Response('original'); };
            eval(bridge);
            const session = 'https://api.readfrog.app/api/identity/get-session';
            const other = 'https://another.example/arbitrary/resource';
            const json = { credentials: 'include', method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' };
            const response = await fetch(new Request(session, { credentials: 'include', cache: 'no-store' }));
            const cloned = response.clone().clone();
            const binary = [...new Uint8Array(await response.arrayBuffer())].join(',');
            const cloneOK = cloned.url === session && cloned.type === 'basic' && !cloned.redirected
              && [...new Uint8Array(await cloned.arrayBuffer())].join(',') === binary;
            for (const method of ['POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']) await fetch(other, { ...json, method, cache: 'reload', redirect: 'error' });
            await fetch(other, { ...json, body: 'plain text', headers: {} });
            await fetch(other, { credentials: 'include', method: 'HEAD' });
            const shared = calls.length === 8 && calls.every(c => c.ns === 'extensionFetch')
              && calls[0].args[0].cache === 'no-store' && calls[1].args[0].cache === 'reload'
              && calls[1].args[0].redirect === 'error' && calls[6].args[0].body === 'plain text';
            const request = new Request(other, json);
            const fallback = await fetch(request);
            const untouched = !request.bodyUsed && normal[0][0] === request;
            let streamController;
            const stream = new ReadableStream({ start(controller) { streamController = controller; } });
            const streaming = fetch(other, { ...json, body: stream });
            const streamUntouched = !stream.locked && normal[1][1].body === stream;
            streamController.close();
            await streaming;
            const cases = [
              [other, { ...json, body: new Uint8Array([255, 0]) }], [other, { ...json, body: new Blob(['x']) }],
              [other, { credentials: 'omit' }], [other, {}], [other, { credentials: 'include', method: 'PROPFIND' }],
              [other, { credentials: 'include', mode: 'same-origin' }], [other, { credentials: 'include', mode: 'no-cors' }],
              [other, { credentials: 'include', integrity: 'sha256-test' }],
              [other, { credentials: 'include', redirect: 'manual' }], [other, { credentials: 'include', keepalive: true }],
              [other, { credentials: 'include', referrer: 'https://explicit.example/' }],
              [other, { credentials: 'include', referrerPolicy: 'origin' }],
              [other, { credentials: 'include', headers: { accept: 'text/event-stream' } }],
              ['data:text/plain,hello', { credentials: 'include' }]
            ];
            for (const [url, options] of cases) await fetch(url, options);
            const unsupportedSkippedBridge = calls.length === 8;
            await fetch('https://unapproved.example/me', { credentials: 'include' });
            const declinedOnce = calls.length === 9 && normal.length === cases.length + 3;
            let networkError = false;
            try { await fetch('https://fails.example/write', json); } catch (error) { networkError = error instanceof TypeError; }
            const noRetry = networkError && normal.length === cases.length + 3;
            const beforeAbort = calls.length;
            const controller = new AbortController();
            controller.abort();
            let aborted = false;
            try { await fetch(session, { credentials: 'include', signal: controller.signal }); }
            catch (error) { aborted = error.name === 'AbortError'; }
            const preAbortedSkippedBridge = calls.length === beforeAbort;
            hold = true;
            const ongoingController = new AbortController();
            const ongoing = fetch(other, { credentials: 'include', signal: ongoingController.signal });
            ongoingController.abort();
            try { await ongoing; } catch (error) { aborted = aborted && error.name === 'AbortError'; }
            const cancelForwarded = calls.at(-1).fn === 'cancel' && calls.at(-1).args[0] === calls.at(-2).args[0].requestID;
            return { binary, cloneOK, shared, untouched, streamUntouched, fallback: await fallback.text(),
                     unsupportedSkippedBridge, declinedOnce, noRetry, aborted, preAbortedSkippedBridge, cancelForwarded };
            """, arguments: ["bridge": ExtensionBridgeScript.source, "extensionID": extensionID], in: nil, contentWorld: .page) as? [String: Any]
        let value = try #require(result)
        #expect(value["binary"] as? String == "0,255,128,65")
        #expect(value["fallback"] as? String == "original")
        for key in ["cloneOK", "shared", "untouched", "streamUntouched", "unsupportedSkippedBridge", "declinedOnce", "noRetry", "aborted", "preAbortedSkippedBridge", "cancelForwarded"] {
            #expect(value[key] as? Bool == true, "Failed fetch behavior: \(key)")
        }
    }

    @Test func accountRequestsDoNotFollowRedirects() async throws {
        let server = try SessionTestServer()
        let url = try await server.start().appendingPathComponent("redirect")
        defer { server.listener.cancel() }
        await #expect(throws: (any Error).self) {
            try await ExtensionFetchRequests().response(["redirect": "error"], url: url, extensionID: "test", store: .nonPersistent())
        }
    }

    @Test func bufferedFetchKeepsTextUploadsAndBinaryResponses() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let bridge = ExtensionFetchRequests(), store = WKWebsiteDataStore.nonPersistent()
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            let response = try #require(try await bridge.response(["method": method, "body": "hello 世界", "cache": "no-store"],
                url: url.appendingPathComponent("echo"), extensionID: "test", store: store) as? [String: Any])
            let encoded = try #require(response["body"] as? String)
            let bytes = try #require(Data(base64Encoded: encoded))
            #expect(String(decoding: bytes, as: UTF8.self) == "hello 世界")
        }
        let response = try #require(try await bridge.response([:], url: url.appendingPathComponent("binary"), extensionID: "test", store: store) as? [String: Any])
        let encoded = try #require(response["body"] as? String)
        #expect(Data(base64Encoded: encoded) == Data([0, 255, 128, 65]))
    }

    @Test func logoutPreservesExtensionOriginAndDeletesOnlyItsProfilesCookie() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let store = WKWebsiteDataStore.nonPersistent(), other = WKWebsiteDataStore.nonPersistent()
        let cookie = try #require(HTTPCookie(properties: [.name: "logout_token", .value: "test-session", .domain: "127.0.0.1", .path: "/",
                                                         .init("SameSite"): "Lax", .init("HttpOnly"): "TRUE"]))
        await store.httpCookieStore.setCookie(cookie)
        await other.httpCookieStore.setCookie(cookie)
        // Payload-supplied origins and cookie headers must not replace the actual sender or profile's cookies.
        let response = try #require(try await ExtensionFetchRequests().response([
            "method": "POST", "body": "{}", "headers": [["Origin", "https://forged.example"], ["Cookie", "session=forged"], ["Content-Type", "application/json"]]
        ], url: url.appendingPathComponent("logout"), extensionID: "test", store: store) as? [String: Any])
        #expect(response["status"] as? Int == 200)
        #expect(await store.httpCookieStore.allCookies().contains { $0.name == "logout_token" } == false)
        #expect(await other.httpCookieStore.allCookies().contains { $0.name == "logout_token" })
        #expect(await store.httpCookieStore.allCookies().contains { $0.name == "refreshed" && $0.isHTTPOnly })
        let headers = try #require(response["headers"] as? [[String]])
        #expect(!headers.contains { $0[0] == "set-cookie" })
    }

    /// Headers a page's fetch may not set stay out of writes, even sent straight to the bridge, as do split lines.
    @Test func writesDropHeadersFetchForbids() {
        for name in ["Cookie", "cookie2", "Origin", "Referer", "Host", "Content-Length", "Connection", "Transfer-Encoding", "TE", "Trailer",
                     "Upgrade", "Via", "Keep-Alive", "Expect", "Date", "DNT", "Accept-Encoding", "Accept-Charset", "Set-Cookie",
                     "Access-Control-Request-Method", "Access-Control-Request-Headers", "Sec-Fetch-Site", "Proxy-Authorization"] {
            #expect(!ExtensionWrite.mayBeSet(name, "x"), "\(name)")
        }
        for name in ["Content-Type", "Authorization", "Accept", "Accept-Language", "X-Requested-With", "User-Agent"] {
            #expect(ExtensionWrite.mayBeSet(name, "x"), "\(name)")
        }
        #expect(!ExtensionWrite.mayBeSet("X-Test", "a\r\nInjected: yes"))
        #expect(!ExtensionWrite.mayBeSet("X-Test", "a\nb"))
        #expect(!ExtensionWrite.mayBeSet("X Test", "a"))
        #expect(!ExtensionWrite.mayBeSet("X-Test:", "a"))
        #expect(!ExtensionWrite.mayBeSet("", "a"))
        #expect(!ExtensionWrite.mayBeSet("X-HTTP-Method-Override", "get, trace"))
        #expect(ExtensionWrite.mayBeSet("X-HTTP-Method-Override", "DELETE"))
    }

    /// Many reads at once open a few pages and queue the rest; cancelling or unloading reaches queued ones too.
    @Test func manyReadsShareAFewPages() async throws {
        let server = try SessionTestServer()
        let url = try await server.start().appendingPathComponent("pending")
        defer { server.listener.cancel() }
        let requests = ExtensionFetchRequests(), store = WKWebsiteDataStore.nonPersistent()
        let count = ExtensionFetchRequests.pageLimit + 2
        let ids = (0..<count).map { _ in UUID() }
        let reads = ids.map { id in
            Task { _ = try await requests.response([:], url: url, extensionID: "test", store: store, requestID: id) }
        }
        for _ in 0..<300 where server.requests.withLock({ $0 }) < ExtensionFetchRequests.pageLimit { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.requests.withLock { $0 } == ExtensionFetchRequests.pageLimit)
        #expect(requests.pageCounts == (ExtensionFetchRequests.pageLimit, 2))
        requests.release("test")
        for read in reads { await #expect(throws: (any Error).self) { try await read.value } }
        #expect(server.requests.withLock { $0 } == ExtensionFetchRequests.pageLimit)
        #expect(requests.pageCounts == (0, 0))
    }

    /// Nothing bigger than the bridge carries is held in memory: reads go to WebKit's streaming fetch, writes fail.
    @Test func bigResponsesAreNeverBuffered() async throws {
        let server = try SessionTestServer()
        let url = try await server.start().appendingPathComponent("huge")
        defer { server.listener.cancel() }
        let read = try await ExtensionFetchRequests().response([:], url: url, extensionID: "test", store: .nonPersistent())
        #expect((read as? [String: Any])?["fallback"] as? Bool == true)
        await #expect(throws: BridgeError.self) {
            try await ExtensionFetchRequests().response(["method": "POST", "body": "{}"], url: url, extensionID: "test", store: .nonPersistent())
        }
        // An upload that big isn't sent here at all.
        let before = server.requests.withLock { $0 }
        let upload = try await ExtensionFetchRequests().response(["method": "POST", "body": String(repeating: "x", count: ExtensionFetchRequests.responseLimit + 1)],
                                                                  url: url, extensionID: "test", store: .nonPersistent())
        #expect((upload as? [String: Any])?["fallback"] as? Bool == true)
        #expect(server.requests.withLock { $0 } == before)
    }

    /// A write says it's the browser, as WebKit's fetch would, unless the extension chose its own user agent.
    @Test func writesSendTheBrowsersUserAgent() async throws {
        let server = try SessionTestServer()
        let url = try await server.start().appendingPathComponent("headers")
        defer { server.listener.cancel() }
        let agent = "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Synthetic"
        func sent(_ options: [String: Any]) async throws -> String {
            let response = try #require(try await ExtensionFetchRequests().response(options, url: url, extensionID: "test", store: .nonPersistent()) as? [String: Any])
            return String(decoding: Data(base64Encoded: try #require(response["body"] as? String)) ?? Data(), as: UTF8.self)
        }
        #expect(try await sent(["method": "POST", "body": "{}", "userAgent": agent]).contains("User-Agent: \(agent)\r\n"))
        let own = try await sent(["method": "POST", "body": "{}", "userAgent": agent, "headers": [["user-agent", "Own/1.0"]]])
        #expect(own.contains("Own/1.0") && !own.contains("Synthetic"))
        // Headers fetch forbids never reach the server, even sent straight to the bridge.
        let forced = try await sent(["method": "POST", "body": "{}", "headers": [["Upgrade", "websocket"], ["Via", "forged"], ["X-Ok", "fine"]]])
        #expect(forced.contains("X-Ok: fine") && !forced.lowercased().contains("upgrade:") && !forced.lowercased().contains("via:"))
    }

    /// A plain-HTTP write to another machine stays with WebKit, which knows the sites kept on HTTPS.
    @Test func plainHTTPWritesLeaveThisMacOnlyThroughWebKit() async throws {
        let response = try await ExtensionFetchRequests().response(["method": "POST", "body": "{}"], url: URL(string: "http://remote.example/write")!,
                                                                    extensionID: "test", store: .nonPersistent())
        #expect((response as? [String: Any])?["fallback"] as? Bool == true)
        for text in ["http://127.0.0.1:8080/", "http://localhost/", "http://dev.localhost/", "http://[::1]:3000/"] {
            #expect(ExtensionFetchRequests.isLoopback(URL(string: text)!), "\(text)")
        }
        for text in ["http://127.0.0.1.evil.example/", "http://localhost.evil.example/", "http://10.0.0.1/", "http://example.com/"] {
            #expect(!ExtensionFetchRequests.isLoopback(URL(string: text)!), "\(text)")
        }
    }

    /// A proxy an extension set through chrome.proxy carries writes too, so they never leave by your own address.
    @Test func writesGoThroughTheProfilesProxy() async throws {
        let proxy = try SessionTestServer()
        let proxyURL = try await proxy.start()
        defer { proxy.listener.cancel() }
        let store = WKWebsiteDataStore.nonPersistent()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(proxyURL.port!))!)
        store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: endpoint)]
        // A made-up site that can't be reached directly: only the proxy can answer for it.
        _ = try? await ExtensionFetchRequests().response(["method": "POST", "body": "{}"], url: URL(string: "https://proxied.example/write")!,
                                                         extensionID: "test", store: store)
        #expect(proxy.requests.withLock { $0 } == 1)
    }

    @Test func writeCancellationAndRevokedAccessPreventDispatch() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let requests = ExtensionFetchRequests(), id = UUID()
        await #expect(throws: BridgeError.self) {
            try await requests.response(["method": "POST"], url: url, extensionID: "test", store: .nonPersistent(), authorize: { false })
        }
        await #expect(throws: (any Error).self) {
            try await requests.response(["method": "POST"], url: url, extensionID: "test", store: .nonPersistent(), requestID: id) {
                requests.cancel(id, extensionID: "test")
                return true
            }
        }
        #expect(server.requests.withLock { $0 } == 0)
    }

    @Test func unloadingAnExtensionCancelsItsDispatchedWrite() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let requests = ExtensionFetchRequests()
        let work = Task {
            _ = try await requests.response(["method": "POST"], url: url.appendingPathComponent("pending"), extensionID: "test", store: .nonPersistent())
            return true
        }
        for _ in 0..<100 where server.requests.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.requests.withLock { $0 } == 1)
        requests.release("test")
        await #expect(throws: (any Error).self) { try await work.value }
    }

    @Test(arguments: ["GET", "POST"])
    func redirectsStayWithinTheAuthorizedOrigin(method: String) async throws {
        let target = try SessionTestServer()
        let targetURL = try await target.start()
        defer { target.listener.cancel() }
        let server = try SessionTestServer(redirectTarget: targetURL.absoluteString)
        let url = try await server.start()
        defer { server.listener.cancel() }
        // A write fails; a read goes to WebKit's own fetch, which follows it without the site's SameSite cookies.
        if method == "GET" {
            let answer = try await ExtensionFetchRequests().response(["method": method], url: url.appendingPathComponent("redirect"), extensionID: "test", store: .nonPersistent())
            #expect((answer as? [String: Any])?["fallback"] as? Bool == true)
        } else {
            await #expect(throws: (any Error).self) {
                try await ExtensionFetchRequests().response(["method": method], url: url.appendingPathComponent("redirect"), extensionID: "test", store: .nonPersistent())
            }
        }
        #expect(target.requests.withLock { $0 } == 0)
        let local = try SessionTestServer()
        let localURL = try await local.start()
        defer { local.listener.cancel() }
        let response = try #require(try await ExtensionFetchRequests().response(["method": method], url: localURL.appendingPathComponent("redirect"), extensionID: "test", store: .nonPersistent()) as? [String: Any])
        #expect(response["redirected"] as? Bool == true)
        #expect(response["url"] as? String == localURL.appendingPathComponent("unexpected").absoluteString)
    }

    /// An extension asking for sites only as optional (Raindrop) reaches a server without CORS headers once "On All
    /// Sites" is chosen, as Chrome does with host access; by default, or for another site listed, it's blocked (#324).
    @Test func chosenAllSitesGivesOptionalHostAccessPastCORS() async throws {
        let server = try SessionTestServer()
        let target = try await server.start()
        defer { server.listener.cancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","host_permissions":[],"optional_host_permissions":["*://*/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)

        func fetched(_ access: ExtensionInstalls.SiteAccess?, sites: [String] = []) async throws -> String {
            let controller = WKWebExtensionController(configuration: .nonPersistent())
            let context = WKWebExtensionContext(for: ext)
            try controller.load(context)
            defer { try? controller.unload(context) }
            for pattern in ExtensionHost.siteAccessPatterns(access, approved: [], optional: ext.optionalPermissionMatchPatterns, sites: sites) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            #expect(BridgeExtensionFetch.allows(target, context: context) == (access == .all))
            let page = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
            page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
            for _ in 0..<100 where page.isLoading || page.title != "page" { try await Task.sleep(for: .milliseconds(100)) }
            #expect(page.title == "page")
            return try await page.callAsyncJavaScript("""
                try { const response = await fetch(target, { credentials: 'omit' }); return String(response.status) + ' ' + await response.text(); }
                catch (error) { return error.name; }
                """, arguments: ["target": target.absoluteString], in: nil, contentWorld: .page) as? String ?? ""
        }
        #expect(try await fetched(nil) == "TypeError")
        #expect(try await fetched(.sites, sites: ["example.com"]) == "TypeError")
        #expect(try await fetched(.all) == #"200 {"signedIn":false}"#)
    }

    @Test func siteAccessChoicesGrantWhatTheySay() throws {
        let required = try WKWebExtension.MatchPattern(string: "https://api.example/*")
        let optional: Set = [try WKWebExtension.MatchPattern(string: "*://*/*")]
        #expect(ExtensionHost.siteAccessPatterns(nil, approved: [required], optional: optional, sites: []) == [required])
        #expect(Set(ExtensionHost.siteAccessPatterns(.all, approved: [required], optional: optional, sites: [])) == optional.union([required]))
        #expect(ExtensionHost.siteAccessPatterns(.click, approved: [required], optional: optional, sites: []).isEmpty)
        #expect(Set(ExtensionHost.siteAccessPatterns(.sites, approved: [], optional: optional, sites: ["raindrop.io"]))
            == Set(ExtensionHost.patterns(for: "raindrop.io")))
    }

    /// A name an extension gives a download stays a plain file name inside Downloads.
    @Test func downloadNamesCantClimbOut() {
        #expect(BridgeDownloads.safeName("../../evil/report.pdf") == "report.pdf")
        #expect(BridgeDownloads.safeName("/etc/passwd") == "passwd")
        #expect(BridgeDownloads.safeName("..\\..\\x.txt") == "x.txt")
        #expect(BridgeDownloads.safeName(".hidden") == "hidden")
        #expect(BridgeDownloads.safeName("a:b.txt") == "a-b.txt")
    }

    /// `chrome.downloads` in one profile sees that profile's downloads only, and never a private window's: what it
    /// can't see it can't erase, open or trash either.
    @Test func downloadsAreSeenOnlyInTheirOwnProfile() {
        let other = UUID()
        let first = DownloadItem(filename: "a.pdf", sourceURL: nil, isPrivate: false)
        let second = DownloadItem(filename: "b.pdf", sourceURL: nil, isPrivate: false, profile: other)
        let hidden = DownloadItem(filename: "c.pdf", sourceURL: nil, isPrivate: true)
        #expect(first.profile == Profile.defaultID)
        #expect(BridgeDownloads.sees(first, in: Profile.defaultID))
        #expect(!BridgeDownloads.sees(first, in: other))
        #expect(BridgeDownloads.sees(second, in: other))
        #expect(!BridgeDownloads.sees(second, in: Profile.defaultID))
        #expect(!BridgeDownloads.sees(hidden, in: Profile.defaultID))
        #expect(!BridgeDownloads.sees(hidden, in: other))
    }

    /// A download fetched again (one listed from before Zigzag started has no store of its own) goes in its own
    /// profile's store, never the one of whichever page is in front: that could be another profile's sign-ins.
    @Test func aDownloadIsFetchedAgainInItsOwnProfile() {
        let made = WKWebsiteDataStore.nonPersistent()
        #expect(DownloadManager.store(for: made, isPrivate: true, profile: Profile.defaultID) === made)
        #expect(DownloadManager.store(for: nil, isPrivate: false, profile: Profile.defaultID) === Profiles.shared.default.store)
        // A private window that's gone, or a profile that's been removed: nowhere to fetch it.
        #expect(DownloadManager.store(for: nil, isPrivate: true, profile: Profile.defaultID) == nil)
        #expect(DownloadManager.store(for: nil, isPrivate: false, profile: UUID()) == nil)
    }
}

/// `runtime.getContexts` like Chrome: background, offscreen, popup, side panel, with filters. Claude's side panel checks its full URL (#112). Only truthful fields are reported.
struct ExtensionContextsTests {
    private let id = "fcoeoabgfenejglbffodgkkbkcdhcgfn"
    private let base = "webkit-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/"
    private var baseURL: URL { URL(string: base)! }
    /// The extension origin as Chrome reports it.
    private var origin: String { String(base.dropLast()) }

    /// A popup with its real URL, not a rebuilt path.
    private final class PopupPage: WKWebView {
        private let address: URL?
        override var url: URL? { address }
        init(_ address: URL?) {
            self.address = address
            super.init(frame: .zero, configuration: WKWebViewConfiguration())
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// Background, offscreen page, and a side panel for one tab.
    private var contexts: [Context] {
        [Context(type: .background, contextID: "background", documentURL: URL(string: base + "zigzag-entry.js")),
         Context(type: .offscreenDocument, contextID: "offscreen", documentURL: URL(string: base + "offscreen.html")),
         Context(type: .sidePanel, contextID: "sidepanel", documentURL: URL(string: base + "sidepanel.html?tabId=770"), tabID: 770)]
    }

    @Test func aSidePanelForOneTabNamesItsTab() {
        let found = BridgeContexts.matching(contexts, filter: ["documentUrls": [base + "sidepanel.html?tabId=770"]])
        #expect(found.count == 1)
        #expect(found.first?.type == .sidePanel)
        #expect(found.first?.tabID == 770)
        #expect(found.first?.dictionary["documentUrl"] as? String == base + "sidepanel.html?tabId=770")
        #expect(found.first?.dictionary["documentOrigin"] as? String == origin)
        // Every other page is no tab's.
        #expect(BridgeContexts.matching(contexts, filter: [:]).map(\.tabID) == [-1, -1, 770])
    }

    @Test func addressesMatchWholeQueryIncluded() {
        #expect(BridgeContexts.matching(contexts, filter: ["documentUrls": [base + "sidepanel.html"]]).isEmpty)
        #expect(BridgeContexts.matching(contexts, filter: ["documentUrls": [base + "sidepanel.html?tabId=771"]]).isEmpty)
    }

    @Test func aPanelForEveryTabIsNoTabs() {
        let panel = [Context(type: .sidePanel, contextID: "sidepanel", documentURL: URL(string: base + "sidepanel.html"))]
        #expect(BridgeContexts.matching(panel, filter: [:]).first?.tabID == -1)
    }

    @Test func filtersNarrowTheAnswer() {
        #expect(BridgeContexts.matching(contexts, filter: ["contextTypes": ["SIDE_PANEL"]]).count == 1)
        #expect(BridgeContexts.matching(contexts, filter: ["tabIds": [770]]).count == 1)
        #expect(BridgeContexts.matching(contexts, filter: ["documentOrigins": [origin]]).count == 3)
        #expect(BridgeContexts.matching(contexts, filter: ["incognito": true]).isEmpty)
    }

    @Test func backgroundWorkerHasNoDocumentFields() throws {
        let worker = try #require(BridgeContexts.background(manifest: ["manifest_version": 3, "background": ["service_worker": "zigzag-entry.js"]],
                                                            baseURL: baseURL, contextID: "background"))
        #expect(worker.type == .background)
        #expect(worker.tabID == -1)
        #expect(worker.windowID == -1)
        #expect(worker.frameID == -1)
        #expect(worker.documentID == nil)
        #expect(worker.documentURL == nil)
        #expect(worker.dictionary["documentId"] == nil)
        #expect(worker.dictionary["documentUrl"] == nil)
        #expect(worker.dictionary["documentOrigin"] == nil)
    }

    @Test func mv2BackgroundPageUsesItsGeneratedPage() throws {
        let declared = try #require(BridgeContexts.background(manifest: ["manifest_version": 2, "background": ["page": "background.html"]],
                                                              baseURL: baseURL, contextID: "background"))
        #expect(declared.documentURL?.absoluteString == base + "background.html")
        #expect(declared.frameID == 0)
        #expect(declared.tabID == -1)
        // Scripts only: Chrome's generated page.
        let generated = try #require(BridgeContexts.background(manifest: ["manifest_version": 2, "background": ["scripts": ["background.js"]]],
                                                               baseURL: baseURL, contextID: "background"))
        #expect(generated.documentURL?.absoluteString == base + "_generated_background_page.html")
        #expect(generated.frameID == 0)
    }

    @Test func anExtensionWithoutBackgroundHasNoBackgroundContext() {
        #expect(BridgeContexts.background(manifest: ["manifest_version": 3], baseURL: baseURL, contextID: "background") == nil)
        #expect(BridgeContexts.background(manifest: ["manifest_version": 2, "background": [String: Any]()], baseURL: baseURL, contextID: "background") == nil)
    }

    @Test func filtersMatchEveryChromeField() {
        let worker = Context(type: .background, contextID: "worker", frameID: -1)
        let panel = Context(type: .sidePanel, contextID: "panel", documentID: "doc-1",
                            documentURL: URL(string: base + "panel.html?tab=7"), tabID: 7, windowID: 3)
        let popup = Context(type: .popup, contextID: "popup", documentURL: URL(string: base + "popup.html"), windowID: 3)
        let all = [worker, panel, popup]
        #expect(BridgeContexts.matching(all, filter: ["contextIds": ["panel"]]).map(\.contextID) == ["panel"])
        #expect(BridgeContexts.matching(all, filter: ["documentIds": ["doc-1"]]).map(\.contextID) == ["panel"])
        #expect(BridgeContexts.matching(all, filter: ["documentOrigins": [origin]]).map(\.contextID) == ["panel", "popup"])
        #expect(BridgeContexts.matching(all, filter: ["documentUrls": [base + "popup.html", base + "panel.html?tab=7"]]).map(\.contextID) == ["panel", "popup"])
        #expect(BridgeContexts.matching(all, filter: ["frameIds": [-1]]).map(\.contextID) == ["worker"])
        #expect(BridgeContexts.matching(all, filter: ["incognito": false]).count == 3)
        #expect(BridgeContexts.matching(all, filter: ["tabIds": [7]]).map(\.contextID) == ["panel"])
        #expect(BridgeContexts.matching(all, filter: ["windowIds": [3]]).map(\.contextID) == ["panel", "popup"])
        #expect(BridgeContexts.matching(all, filter: ["contextTypes": ["POPUP", "BACKGROUND"]]).map(\.contextID) == ["worker", "popup"])
        // Each filter field narrows; values within one widen.
        #expect(BridgeContexts.matching(all, filter: ["windowIds": [3], "contextTypes": ["POPUP"]]).map(\.contextID) == ["popup"])
        #expect(BridgeContexts.matching(all, filter: ["windowIds": [4]]).isEmpty)
        #expect(BridgeContexts.matching(all, filter: [:]).count == 3)
    }

    @Test func filtersMatchAbsentDocumentFieldsAsEmpty() {
        let worker = Context(type: .background, contextID: "worker", frameID: -1)
        let popup = Context(type: .popup, contextID: "popup", documentURL: URL(string: base + "popup.html"))
        let all = [worker, popup]
        // An empty list matches nothing; an absent field matches everything.
        #expect(BridgeContexts.matching(all, filter: ["contextIds": []]).isEmpty)
        #expect(BridgeContexts.matching(all, filter: ["documentUrls": []]).isEmpty)
        #expect(BridgeContexts.matching(all, filter: ["contextTypes": []]).isEmpty)
        // A document filter skips contexts without a document.
        #expect(BridgeContexts.matching(all, filter: ["documentUrls": [base + "popup.html"]]).map(\.contextID) == ["popup"])
        #expect(BridgeContexts.matching(all, filter: ["documentIds": ["anything"]]).isEmpty)
        #expect(BridgeContexts.matching(all, filter: ["documentOrigins": [origin]]).map(\.contextID) == ["popup"])
    }

    @Test func contextIdsAreStableAcrossCalls() {
        let names = ContextNames()
        let panel = NSObject()
        let first = names.name(of: panel, extensionID: "one")
        #expect(names.name(of: panel, extensionID: "one") == first)
        #expect(names.name(of: NSObject(), extensionID: "one") != first)
        // Two popups on the same page are two contexts.
        let url = URL(string: base + "popup.html")!
        let one = PopupPage(url), two = PopupPage(url)
        let oneID = names.name(of: one, extensionID: "one")
        #expect(names.name(of: two, extensionID: "one") != oneID)
        // Closed contexts are forgotten; reopening gives a new ID.
        names.keeping([names.name(of: two, extensionID: "one")], extensionID: "one")
        #expect(names.name(of: one, extensionID: "one") != oneID)
    }

    @Test func contextIdsAreKeptPerExtension() {
        let names = ContextNames()
        let first = NSObject(), second = NSObject()
        let firstID = names.name(of: first, extensionID: "one")
        let secondID = names.name(of: second, extensionID: "two")
        // Names are per extension.
        #expect(names.name(of: first, extensionID: "two") != firstID)
        // One extension's sweep doesn't touch another's.
        names.keeping([firstID], extensionID: "one")
        #expect(names.name(of: second, extensionID: "two") == secondID)
        // Nor revive its closed context.
        names.keeping([], extensionID: "two")
        #expect(names.name(of: second, extensionID: "two") != secondID)
    }

    @Test func documentIdsAreNotInvented() throws {
        let worker = try #require(BridgeContexts.background(manifest: ["manifest_version": 3, "background": ["service_worker": "zigzag-entry.js"]],
                                                            baseURL: baseURL, contextID: "background"))
        let page = try #require(BridgeContexts.background(manifest: ["manifest_version": 2, "background": ["page": "background.html"]],
                                                          baseURL: baseURL, contextID: "background"))
        let popup = Context(type: .popup, contextID: "popup", documentURL: URL(string: base + "popup.html"))
        let panel = Context(type: .sidePanel, contextID: "panel", documentURL: URL(string: base + "panel.html"), tabID: 770)
        for context in [worker, page, popup, panel] {
            #expect(context.documentID == nil)
            #expect(context.dictionary["documentId"] == nil)
        }
        #expect(popup.dictionary["documentUrl"] as? String == base + "popup.html")
        #expect(panel.dictionary["tabId"] as? Int == 770)
    }

    @Test func aPopupKeepsItsQueryString() throws {
        // The URL is `WKWebView.url`, not the path `shownPopupPage` gives tab capture.
        let address = try #require(URL(string: base + "popup.html?tabId=770&view=side"))
        let page = PopupPage(address)
        let names = ContextNames()
        let popup = BridgeContexts.popup(page, contextID: names.name(of: page, extensionID: "one"))
        #expect(popup.documentURL?.absoluteString == base + "popup.html?tabId=770&view=side")
        #expect(popup.dictionary["documentUrl"] as? String == base + "popup.html?tabId=770&view=side")
        #expect(BridgeContexts.matching([popup], filter: ["documentUrls": [base + "popup.html?tabId=770&view=side"]]).count == 1)
        #expect(BridgeContexts.matching([popup], filter: ["documentUrls": [base + "popup.html"]]).isEmpty)
        // Identity is the page object, not its URL.
        #expect(names.name(of: page, extensionID: "one") == popup.contextID)
    }
}

/// An extension's notification is named so a click on it finds the extension again, in its own profile.
struct ExtensionNotificationKeyTests {
    private let rabby = "acmacodkjbdgmoleebolmdjonilkdbch"

    @Test func theFirstProfilesKeepTheirForm() {
        let key = ExtensionNotificationKey(profile: nil, extensionID: rabby, id: "tx-1")
        #expect(key.string == "ext|\(rabby)|tx-1")
        #expect(ExtensionNotificationKey(key.string) == key)
    }

    @Test func anotherProfilesNameIt() throws {
        let profile = try #require(UUID(uuidString: "B2222222-2222-4222-8222-222222222222"))
        let key = ExtensionNotificationKey(profile: profile, extensionID: rabby, id: "tx-1")
        #expect(key.string == "ext|B2222222-2222-4222-8222-222222222222|\(rabby)|tx-1")
        #expect(ExtensionNotificationKey(key.string) == key)
    }

    @Test func anIDMayHoldBarsAndBeEmpty() {
        #expect(ExtensionNotificationKey("ext|\(rabby)|a|b")?.id == "a|b")
        #expect(ExtensionNotificationKey("ext|\(rabby)|")?.id == "")
    }

    @Test func whatIsntAnExtensionsIsRefused() {
        #expect(ExtensionNotificationKey("site|example.com|1") == nil)
        #expect(ExtensionNotificationKey("ext|\(rabby)") == nil)
    }
}

/// A local account endpoint: only made-up cookies, in a store that goes away after each test.
nonisolated private final class SessionTestServer: @unchecked Sendable {
    let listener: NWListener
    let requests = OSAllocatedUnfairLock(initialState: 0)
    private let queue = DispatchQueue(label: "zigzag.tests.site-session")

    init(redirectTarget: String = "/unexpected") throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue, requests = requests
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receive(connection, bytes: Data(), requests: requests, redirectTarget: redirectTarget)
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { done in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    done.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    done.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private static func receive(_ connection: NWConnection, bytes: Data, requests: OSAllocatedUnfairLock<Int>, redirectTarget: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var bytes = bytes
            if let data { bytes.append(data) }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil && bytes.count < 65536 { receive(connection, bytes: bytes, requests: requests, redirectTarget: redirectTarget) }
                else { connection.cancel() }
                return
            }
            let text = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
            let length = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard bytes.count >= boundary.upperBound + length else {
                if !complete && error == nil { receive(connection, bytes: bytes, requests: requests, redirectTarget: redirectTarget) }
                else { connection.cancel() }
                return
            }
            requests.withLock { $0 += 1 }
            let path = text.components(separatedBy: " ").dropFirst().first ?? "/"
            if path == "/huge" {
                // Says it's far bigger than the bridge carries, then sends only a little of it.
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 40000000\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + Data(count: 1024), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if path == "/pending" {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
                return
            }
            let redirect = path == "/redirect"
            let signedIn = text.components(separatedBy: "\r\n").contains { $0.lowercased().hasPrefix("cookie:") && $0.contains("session=synthetic") }
            let body = path == "/binary" ? Data([0, 255, 128, 65])
                : path == "/echo" ? Data(bytes[boundary.upperBound..<(boundary.upperBound + length)])
                : path == "/headers" ? Data(text.utf8)
                : Data("{\"signedIn\":\(signedIn)}".utf8)
            let logoutOK = text.components(separatedBy: "\r\n").contains { $0.lowercased() == "origin: chrome-extension://test" }
                && text.components(separatedBy: "\r\n").contains { $0.lowercased().hasPrefix("cookie:") && $0.contains("logout_token=test-session") && !$0.contains("session=forged") }
            let status = redirect ? "302 Found" : path == "/logout" && !logoutOK ? "403 Forbidden" : "200 OK"
            let deleted = path == "/logout" ? "Set-Cookie: logout_token=; Max-Age=0; Path=/; HttpOnly\r\n" : ""
            let headers = redirect ? "Location: \(redirectTarget)\r\n" : deleted + "Set-Cookie: refreshed=synthetic; Path=/; SameSite=Lax; HttpOnly\r\n"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nCache-Control: public, max-age=3600\r\n\(headers)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Numbers an extension passes become whole numbers without a trap, whatever they are, and a bookmark's index lands
/// inside its list.
struct ExtensionNumberTests {
    @Test func anyNumberBecomesAnIntWithoutATrap() {
        #expect(Int(saturating: 1e300) == .max)
        #expect(Int(saturating: -1e300) == .min)
        #expect(Int(saturating: .infinity) == .max)
        #expect(Int(saturating: -.infinity) == .min)
        #expect(Int(saturating: .nan) == 0)
        #expect(Int(saturating: Double(Int.max)) == .max)
        #expect(Int(saturating: 9.7) == 9)
        #expect(Int(saturating: -3.2) == -3)
        #expect(Int(saturating: 42) == 42)
    }

    @Test func aBookmarksIndexStaysInItsList() {
        #expect(Library.place(-1, among: 3) == 0)
        #expect(Library.place(Int(saturating: -1e300), among: 3) == 0)
        #expect(Library.place(Int(saturating: 1e300), among: 3) == 3)
        #expect(Library.place(nil, among: 3) == 3)
        #expect(Library.place(1, among: 3) == 1)
        #expect(Library.place(0, among: 0) == 0)
    }
}

extension ExtensionBridgeTests {
    /// Background WebSockets need local, host_permissions, or granted optional hosts; wss://host counts as https://host.
    @Test func backgroundSocketsNeedHostAccess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","host_permissions":["https://named.example/*"],"optional_host_permissions":["https://push.example/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        #expect(WebSocketBridge.allows(URL(string: "wss://named.example/socket")!, context: context, localReceivers: false))
        #expect(!WebSocketBridge.allows(URL(string: "wss://push.example/socket")!, context: context, localReceivers: false))
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://push.example/*"))
        #expect(WebSocketBridge.allows(URL(string: "wss://push.example/socket")!, context: context, localReceivers: false))
        // This Mac needs the person's switch for this extension, and a host permission is not one.
        for text in ["ws://localhost:8080/", "ws://127.0.0.1:1234/x", "ws://127.5.6.7/", "ws://[::1]:9000/", "wss://LOCALHOST./"] {
            #expect(!WebSocketBridge.allows(URL(string: text)!, context: context, localReceivers: false))
            #expect(WebSocketBridge.allows(URL(string: text)!, context: context, localReceivers: true))
        }
        for text in ["ws://push.example/socket", "wss://other.example/socket", "wss://push.example.evil.test/",
                     "wss://name:synthetic@push.example/", "https://push.example/socket", "ws://128.0.0.1/",
                     "ws://localhost.evil.test/", "ws://127.0.0.1.evil.test/", "ws://user:pw@localhost/", "http://localhost/"] {
            #expect(!WebSocketBridge.allows(URL(string: text)!, context: context, localReceivers: false), "\(text) is refused")
            #expect(!WebSocketBridge.allows(URL(string: text)!, context: context, localReceivers: true), "\(text) is refused")
        }
    }
}

extension ExtensionBridgeTests {
    /// downloads.search filenameRegex runs off the main thread with a timeout.
    @Test func downloadSearchPatternsGiveUp() async {
        let names = ["/Users/me/Downloads/report.pdf", "/Users/me/Downloads/photo.png", String(repeating: "a", count: 40) + "!"]
        #expect(await BridgeDownloads.matching(#"\.pdf$"#, in: names) == [0])
        #expect(await BridgeDownloads.matching("(unclosed", in: names) == [])
        #expect(!BridgeDownloads.isValidPattern("(unclosed") && BridgeDownloads.isValidPattern(#"\.pdf$"#))
        let started = Date()
        #expect(await BridgeDownloads.matching("^(a+)+$", in: names, timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// Extension log lines stay single-line and short.
    @Test func extensionLogLinesStayShort() {
        #expect(ExtensionLog.entry("socket to example.com closed") == "socket to example.com closed")
        #expect(ExtensionLog.entry("name\n2026-01-01 Zigzag: fake line\r\u{2028}x") == "name 2026-01-01 Zigzag: fake line  x")
        let long = ExtensionLog.entry(String(repeating: "é", count: 10_000))
        #expect(long.unicodeScalars.count == ExtensionLog.lineLimit + 1 && long.hasSuffix("…"))
    }

    /// Sound tap chunks are capped at the sent size.
    @Test func tapChunksAreCapped() {
        #expect(BridgeTabCapture.acceptsChunk(pcm: String(repeating: "A", count: 44_000), rate: 48_000))
        #expect(!BridgeTabCapture.acceptsChunk(pcm: String(repeating: "A", count: BridgeTabCapture.maxChunkCharacters + 1), rate: 48_000))
        #expect(!BridgeTabCapture.acceptsChunk(pcm: "AAAA", rate: 0))
        #expect(!BridgeTabCapture.acceptsChunk(pcm: "AAAA", rate: .infinity))
    }

    /// A per-tab side panel shows there even when off globally (ChatGPT).
    @Test func sidePanelTabOptionWinsOverEveryTab() {
        if #available(macOS 15.4, *) {
            #expect(BridgeSidePanel.isEnabled(everywhere: false, forTab: true))
            #expect(!BridgeSidePanel.isEnabled(everywhere: true, forTab: false))
            #expect(!BridgeSidePanel.isEnabled(everywhere: false, forTab: nil))
            #expect(BridgeSidePanel.isEnabled(everywhere: true, forTab: nil))
        }
    }
}

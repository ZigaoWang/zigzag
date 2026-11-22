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
            try await bridge.response([:], url: url, extensionID: "test", store: .nonPersistent(), authorize: { _ in false })
        }
        let duringSetup = UUID()
        await #expect(throws: BridgeError.self) {
            try await bridge.response([:], url: url, extensionID: "test", store: .nonPersistent(), requestID: duringSetup) { _ in
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

    @Test func defaultCredentialFetchStepsInOnlyForSameSiteCookies() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "https://account.example/api/me"))
        func cookie(_ name: String, domain: String, sameSite: String?) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "synthetic", .domain: domain, .path: "/", .secure: "TRUE"]
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            return try #require(HTTPCookie(properties: properties))
        }
        #expect(await BridgeExtensionFetch.keepsSameSiteCookies(url, in: store) == false)
        // WebKit's own fetch sends these, so the bridge leaves them to it.
        await store.httpCookieStore.setCookie(try cookie("plain", domain: "account.example", sameSite: nil))
        await store.httpCookieStore.setCookie(try cookie("elsewhere", domain: "other.example", sameSite: "lax"))
        #expect(await BridgeExtensionFetch.keepsSameSiteCookies(url, in: store) == false)
        await store.httpCookieStore.setCookie(try cookie("session", domain: ".account.example", sameSite: "lax"))
        #expect(await BridgeExtensionFetch.keepsSameSiteCookies(url, in: store))
        #expect(await BridgeExtensionFetch.keepsSameSiteCookies(try #require(URL(string: "https://other.example/")), in: store))
        let scoped = ExtensionWrite.scoped(await store.httpCookieStore.allCookies(), to: url).map(\.name).sorted()
        #expect(scoped == ["plain", "session"])
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
            // Left at the default, as Chrome sends cookies then too; the native side decides whether it steps in.
            await fetch(other, {});
            await fetch(other, { ...json, credentials: 'same-origin' });
            const defaults = calls.length === 10 && calls[0].args[0].credentials === 'include'
              && calls[8].args[0].credentials === 'same-origin' && calls[9].args[0].credentials === 'same-origin';
            // Form data, a Blob or a buffer crosses as base64 bytes, matching the Content-Type its request made.
            const form = new FormData();
            form.append('data[gpg_auth][keyid]', 'FP');
            await fetch(other, { credentials: 'include', method: 'POST', body: form });
            await fetch(other, { ...json, body: new Uint8Array([255, 0]) });
            await fetch(other, { ...json, body: new Blob(['x']) });
            const [sentForm, sentBuffer, sentBlob] = calls.slice(10).map(c => c.args[0]);
            const formType = new Map(sentForm.headers).get('content-type') || '';
            const boundary = formType.split('boundary=')[1];
            const formText = atob(sentForm.body);
            const binaryBodies = calls.length === 13 && sentForm.encoding === 'base64' && formType.startsWith('multipart/form-data')
              && !!boundary && formText.includes('--' + boundary) && formText.includes('name="data[gpg_auth][keyid]"')
              && sentBuffer.encoding === 'base64' && sentBuffer.body === btoa(String.fromCharCode(255, 0))
              && sentBlob.encoding === 'base64' && sentBlob.body === btoa('x') && calls[6].args[0].encoding === undefined;
            // Over the 32 MB limit, a body goes to WebKit without being read or encoded; at it, to the bridge.
            const limit = 32 << 20, bigForm = new FormData();
            bigForm.append('file', new Blob([new Uint8Array(limit + 1)]));
            const over = [new Uint8Array(limit + 1), new Blob([new Uint8Array(limit + 1)]), bigForm, 'x'.repeat(limit + 1)];
            for (const body of over) await fetch(other, { ...json, body });
            const overSkippedBridge = calls.length === 13 && normal.length === over.length;
            await fetch(other, { ...json, body: new Uint8Array(limit) });
            const capped = overSkippedBridge && calls.length === 14 && calls[13].args[0].body.length === Math.ceil(limit / 3) * 4;
            calls.length = 10;
            normal.length = 0;
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
              [other, { credentials: 'include', method: 'PROPFIND' }],
              [other, { credentials: 'include', mode: 'same-origin' }], [other, { credentials: 'include', mode: 'no-cors' }],
              [other, { credentials: 'include', integrity: 'sha256-test' }],
              [other, { credentials: 'include', redirect: 'manual' }], [other, { credentials: 'include', keepalive: true }],
              [other, { credentials: 'include', referrer: 'https://explicit.example/' }],
              [other, { credentials: 'include', referrerPolicy: 'origin' }],
              [other, { credentials: 'include', headers: { accept: 'text/event-stream' } }],
              ['data:text/plain,hello', { credentials: 'include' }]
            ];
            for (const [url, options] of cases) await fetch(url, options);
            const unsupportedSkippedBridge = calls.length === 10;
            await fetch('https://unapproved.example/me', { credentials: 'include' });
            const declinedOnce = calls.length === 11 && normal.length === cases.length + 3;
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
            return { binary, cloneOK, shared, defaults, binaryBodies, capped, untouched, streamUntouched, fallback: await fallback.text(),
                     unsupportedSkippedBridge, declinedOnce, noRetry, aborted, preAbortedSkippedBridge, cancelForwarded };
            """, arguments: ["bridge": ExtensionBridgeScript.source, "extensionID": extensionID], in: nil, contentWorld: .page) as? [String: Any]
        let value = try #require(result)
        #expect(value["binary"] as? String == "0,255,128,65")
        #expect(value["fallback"] as? String == "original")
        for key in ["cloneOK", "shared", "defaults", "binaryBodies", "capped", "untouched", "streamUntouched", "unsupportedSkippedBridge", "declinedOnce", "noRetry", "aborted", "preAbortedSkippedBridge", "cancelForwarded"] {
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

    /// Passbolt signs in with form data (#393): its bytes reach the site as written, and the session cookie the
    /// answer sets lands in the profile, where the next request and chrome.cookies find it.
    @Test func formDataWritesSendTheirBytesAndKeepTheSessionCookie() async throws {
        let server = try SessionTestServer()
        let url = try await server.start().appendingPathComponent("echo")
        defer { server.listener.cancel() }
        let store = WKWebsiteDataStore.nonPersistent()
        let form = Data("--b\r\nContent-Disposition: form-data; name=\"data[gpg_auth][keyid]\"\r\n\r\nFP\r\n--b--\r\n".utf8) + Data([0, 255])
        let response = try #require(try await ExtensionFetchRequests().response(
            ["method": "POST", "credentials": "include", "body": form.base64EncodedString(), "encoding": "base64",
             "headers": [["content-type", "multipart/form-data; boundary=b"]]],
            url: url, extensionID: "test", store: store) as? [String: Any])
        let echoed = try #require((response["body"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(echoed == form)
        #expect(await store.httpCookieStore.allCookies().contains { $0.name == "refreshed" && $0.sameSitePolicy == .sameSiteLax })
        #expect(ExtensionFetchRequests.body(["body": "plain", "encoding": "base64"]) == nil)
        #expect(ExtensionFetchRequests.body(["body": "plain"]) == Data("plain".utf8))
        #expect(ExtensionFetchRequests.body(["body": "AP8=", "encoding": "base64"]) == Data([0, 255]))
    }

    /// A body over the limit falls back to WebKit, its size read from the base64 length rather than by decoding it.
    @Test func oversizedBodiesFallBackBeforeDecoding() async throws {
        for count in 0...5 {
            #expect(ExtensionFetchRequests.base64Size(Data(repeating: 7, count: count).base64EncodedString()) == count)
        }
        let limit = ExtensionFetchRequests.responseLimit
        #expect(ExtensionFetchRequests.bodySize(["body": Data(count: limit).base64EncodedString(), "encoding": "base64"]) == limit)
        #expect(ExtensionFetchRequests.bodySize(["body": "hello 世界"]) == 12)
        let over = Data(count: limit + 1).base64EncodedString()
        let options: [String: Any] = ["method": "POST", "body": over, "encoding": "base64"]
        let url = try #require(URL(string: "https://example.invalid/upload"))
        let written = try await ExtensionFetchRequests().response(options, url: url, extensionID: "test", store: .nonPersistent()) as? [String: Any]
        #expect(written?["fallback"] as? Bool == true)
        let direct = try await ExtensionFetchRequests().direct(options, url: url, extensionID: "test", store: .nonPersistent(),
                                                               authorize: { _ in true }) as? [String: Any]
        #expect(direct?["fallback"] as? Bool == true)
        let local = try #require(URL(string: "http://127.0.0.1:1/upload"))
        #expect(throws: BridgeError.self) { try BridgeExtensionFetch.localReceiverRequest(["method": "POST", "body": over], url: local) }
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
        // The connection to the proxy can be tried again when it can't finish the tunnel.
        #expect(proxy.requests.withLock { $0 } >= 1)
    }

    @Test func writeCancellationAndRevokedAccessPreventDispatch() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let requests = ExtensionFetchRequests(), id = UUID()
        await #expect(throws: BridgeError.self) {
            try await requests.response(["method": "POST"], url: url, extensionID: "test", store: .nonPersistent(), authorize: { _ in false })
        }
        await #expect(throws: (any Error).self) {
            try await requests.response(["method": "POST"], url: url, extensionID: "test", store: .nonPersistent(), requestID: id) { _ in
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

    /// Default credentials (YouMind's sign-in check): a redirect to another site the extension may reach is followed
    /// here with that site's cookies, once, never handed to WebKit to send again.
    @Test(arguments: ["GET", "POST"])
    func defaultCredentialRedirectsToAnotherReachableSiteAreFollowedOnce(method: String) async throws {
        let target = try SessionTestServer()
        let targetURL = try await target.start()
        defer { target.listener.cancel() }
        let server = try SessionTestServer(redirectTarget: targetURL.appendingPathComponent("me").absoluteString)
        let url = try await server.start()
        defer { server.listener.cancel() }
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(try #require(HTTPCookie(properties: [.name: "session", .value: "synthetic", .domain: "127.0.0.1", .path: "/", .init("SameSite"): "Lax"])))
        let options: [String: Any] = method == "POST" ? ["method": method, "body": "{}"] : ["method": method]
        let response = try #require(try await ExtensionFetchRequests().direct(options,
            url: url.appendingPathComponent("redirect"), extensionID: "test", store: store) { _ in true } as? [String: Any])
        #expect(response["redirected"] as? Bool == true)
        #expect(response["url"] as? String == targetURL.appendingPathComponent("me").absoluteString)
        let body = String(decoding: Data(base64Encoded: try #require(response["body"] as? String)) ?? Data(), as: UTF8.self)
        #expect(body.contains("\"signedIn\":true"))
        #expect(server.requests.withLock { $0 } == 1)
        #expect(target.requests.withLock { $0 } == 1)
    }

    /// A site the extension may not reach gets no cookies and must allow it by CORS; each hop is checked as it's made.
    @Test func defaultCredentialRedirectsAreCheckedHopByHop() async throws {
        let target = try SessionTestServer()
        let targetURL = try await target.start()
        defer { target.listener.cancel() }
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(try #require(HTTPCookie(properties: [.name: "session", .value: "synthetic", .domain: "127.0.0.1", .path: "/", .init("SameSite"): "Lax"])))
        for (path, allowed) in [("open", true), ("me", false)] {
            let server = try SessionTestServer(redirectTarget: targetURL.appendingPathComponent(path).absoluteString)
            let url = try await server.start()
            defer { server.listener.cancel() }
            let port = url.port
            let send = { try await ExtensionFetchRequests().direct([:], url: url.appendingPathComponent("redirect"), extensionID: "test", store: store) { $0.port == port } }
            if allowed {
                let response = try #require(try await send() as? [String: Any])
                let body = String(decoding: Data(base64Encoded: try #require(response["body"] as? String)) ?? Data(), as: UTF8.self)
                #expect(body.contains("\"signedIn\":false"))
            } else {
                await #expect(throws: BridgeError.self) { try await send() }
            }
            #expect(server.requests.withLock { $0 } == 1)
        }
        #expect(target.requests.withLock { $0 } == 2)
        // Within the site too: a hop to a path the extension can't reach goes no further.
        let local = try SessionTestServer()
        let localURL = try await local.start()
        defer { local.listener.cancel() }
        await #expect(throws: BridgeError.self) {
            try await ExtensionFetchRequests().direct([:], url: localURL.appendingPathComponent("redirect"), extensionID: "test", store: store) { $0.path != "/unexpected" }
        }
        #expect(local.requests.withLock { $0 } == 1)
    }

    /// What default credentials can't carry here goes to WebKit's fetch before anything is sent.
    @Test func defaultCredentialFetchDecidesBeforeSending() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let requests = ExtensionFetchRequests()
        for (options, target) in [([String: Any](), URL(string: "http://remote.example/api")!),
                                  (["headers": [["Accept", "text/event-stream"]]], url),
                                  (["method": "GET", "body": "x"], url),
                                  (["method": "POST", "body": String(repeating: "x", count: ExtensionFetchRequests.responseLimit + 1)], url)] {
            let answer = try await requests.direct(options, url: target, extensionID: "test", store: .nonPersistent()) { _ in true }
            #expect((answer as? [String: Any])?["fallback"] as? Bool == true)
        }
        #expect(server.requests.withLock { $0 } == 0)
        // A slow read isn't cut short: it ends when its extension lets go of it.
        let id = UUID()
        let slow = Task { _ = try await requests.direct([:], url: url.appendingPathComponent("pending"), extensionID: "test", store: .nonPersistent(), requestID: id) { _ in true } }
        for _ in 0..<300 where server.requests.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.requests.withLock { $0 } == 1)
        requests.cancel(id, extensionID: "test")
        await #expect(throws: (any Error).self) { try await slow.value }
    }

    /// The SameSite check is read once per host until the profile's cookies change.
    @Test func sameSiteCheckIsKeptUntilCookiesChange() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let url = try #require(URL(string: "https://account.example/api/me"))
        let check = SameSiteCookieCheck()
        #expect(await check.has(url, in: store) == false)
        #expect(check.count == 1)
        await store.httpCookieStore.setCookie(try #require(HTTPCookie(properties: [.name: "s", .value: "1", .domain: "account.example", .path: "/", .secure: "TRUE", .sameSitePolicy: "lax"])))
        for _ in 0..<200 where check.count > 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(check.count == 0)
        #expect(await check.has(url, in: store))
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

    /// Litewarden (#478): a fetch with credentials: 'omit' and its own headers, to a server that sends no CORS headers.
    /// With host access it goes natively, without the profile's cookies, with its headers; without, it stays WebKit's,
    /// bound by CORS.
    @Test func omitFetchWithHostAccessGetsPastCORSWithoutCookies() async throws {
        let server = try SessionTestServer()
        let target = try await server.start().appendingPathComponent("headers")
        defer { server.listener.cancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","host_permissions":["<all_urls>"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<!doctype html><title>page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        // The profile has a session cookie for the server; omit must not send it.
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(try #require(HTTPCookie(properties: [.name: "session", .value: "synthetic", .domain: "127.0.0.1", .path: "/"])))

        func fetched(granted: Bool, bridged: Bool) async throws -> String {
            let controller = WKWebExtensionController(configuration: .nonPersistent())
            let context = WKWebExtensionContext(for: ext)
            try controller.load(context)
            defer { try? controller.unload(context) }
            if granted { context.setPermissionStatus(.grantedExplicitly, for: .allURLs()) }
            let configuration = try #require(context.webViewConfiguration)
            let door = HostAccessFetchDoor(context: context, store: store)
            configuration.userContentController.addScriptMessageHandler(door, contentWorld: .page, name: "door")
            let page = WKWebView(frame: .zero, configuration: configuration)
            page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
            for _ in 0..<100 where page.isLoading || page.title != "page" { try await Task.sleep(for: .milliseconds(100)) }
            #expect(page.title == "page")
            if bridged {
                // The page's policy allows no eval: the bridge runs as a script of its own, as Zigzag runs it.
                _ = try await page.callAsyncJavaScript("""
                    const runtime = { id: 'test', getManifest: () => ({}),
                      sendNativeMessage: (host, message) => window.webkit.messageHandlers.door.postMessage(message)
                        .then((value) => ({ value }), (error) => ({ error: String(error && error.message || error) })) };
                    Object.defineProperty(globalThis, 'chrome', { value: { runtime }, configurable: true, writable: true });
                    """, in: nil, contentWorld: .page)
                _ = try await page.callAsyncJavaScript(ExtensionBridgeScript.source, in: nil, contentWorld: .page)
            }
            return try await page.callAsyncJavaScript("""
                try {
                  const response = await fetch(target, { credentials: 'omit', cache: 'no-store',
                    headers: { 'Bitwarden-Client-Name': 'web', 'Device-Type': '9' } });
                  const text = (await response.text()).toLowerCase();
                  return [response.status, response.headers.get('content-type'), text.includes('bitwarden-client-name: web'),
                          text.includes('device-type: 9'), text.includes('origin: chrome-extension://test'), text.includes('cookie:')].join(' ');
                } catch (error) { return error.name; }
                """, arguments: ["target": target.absoluteString], in: nil, contentWorld: .page) as? String ?? ""
        }
        // The cause: WebKit's own fetch is past CORS for a simple request only, not one it asks the server about first.
        #expect(try await fetched(granted: true, bridged: true) == "200 application/octet-stream true true true false")
        #expect(try await fetched(granted: false, bridged: true) == "TypeError")
        #expect(try await fetched(granted: false, bridged: false) == "TypeError")
        // Nothing the server set came back into the profile.
        #expect(await store.httpCookieStore.allCookies().map(\.name) == ["session"])
    }

    /// Omit goes natively with no cookie out and none kept, its headers, method and body as sent and its answer's
    /// status, headers and body as they came; default credentials without SameSite cookies stay WebKit's.
    @Test func omitRequestsSendTheirHeadersAndBodyWithoutCookies() async throws {
        let server = try SessionTestServer()
        let url = try await server.start()
        defer { server.listener.cancel() }
        let store = WKWebsiteDataStore.nonPersistent()
        await store.httpCookieStore.setCookie(try #require(HTTPCookie(properties: [.name: "session", .value: "synthetic", .domain: "127.0.0.1", .path: "/", .init("SameSite"): "Lax"])))
        let requests = ExtensionFetchRequests()
        func send(_ options: [String: Any], _ path: String) async throws -> [String: Any] {
            try #require(try await requests.withHostAccess(options, url: url.appendingPathComponent(path), extensionID: "test", store: store,
                                                           keepsSameSiteCookies: { false }, authorize: { _ in true }) as? [String: Any])
        }
        func text(_ answer: [String: Any]) -> String {
            String(decoding: Data(base64Encoded: answer["body"] as? String ?? "") ?? Data(), as: UTF8.self)
        }
        let headers = try await send(["credentials": "omit", "method": "GET", "cache": "no-store",
                                      "headers": [["bitwarden-client-name", "web"], ["device-type", "9"]]], "headers")
        #expect(headers["status"] as? Int == 200)
        let sent = text(headers).lowercased()
        #expect(sent.hasPrefix("get /headers "))
        #expect(sent.contains("bitwarden-client-name: web") && sent.contains("device-type: 9"))
        #expect(sent.contains("origin: chrome-extension://test"))
        #expect(!sent.contains("cookie:"))
        let answered = try #require(headers["headers"] as? [[String]])
        #expect(answered.contains(["content-type", "application/octet-stream"]))
        #expect(answered.contains(["cache-control", "public, max-age=3600"]))
        #expect(!answered.contains { $0[0] == "set-cookie" })
        for method in ["POST", "PUT", "DELETE"] {
            let echo = try await send(["credentials": "omit", "method": method, "body": #"{"email":"a@b.c"}"#,
                                       "headers": [["content-type", "application/json"]]], "echo")
            #expect(text(echo) == #"{"email":"a@b.c"}"#)
        }
        let binary = try await send(["credentials": "omit", "method": "POST", "body": "AP8=", "encoding": "base64",
                                     "headers": [["content-type", "application/octet-stream"]]], "echo")
        #expect(Data(base64Encoded: binary["body"] as? String ?? "") == Data([0, 255]))
        #expect(text(try await send(["credentials": "omit", "method": "GET"], "me")) == #"{"signedIn":false}"#)
        // Nothing the server set came back into the profile.
        #expect(await store.httpCookieStore.allCookies().map(\.name) == ["session"])
        // A read too big to carry whole is WebKit's to stream, as with other credentials.
        #expect(try await send(["credentials": "omit", "method": "GET"], "huge")["fallback"] as? Bool == true)
        let before = server.requests.withLock { $0 }
        #expect(try await send(["credentials": "same-origin", "method": "GET"], "me")["fallback"] as? Bool == true)
        #expect(server.requests.withLock { $0 } == before)
    }

    /// bridge.js hands omit to Zigzag like the other credentials, with what the request carries, and reads the answer
    /// as sent; Zigzag's fallback answer, as without host access, leaves it to WebKit.
    @Test func omitFetchGoesToZigzag() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        let result = try await page.callAsyncJavaScript("""
            const calls = [], normal = [];
            if (!crypto.randomUUID) crypto.randomUUID = () => '00000000-0000-4000-8000-000000000000';
            globalThis.chrome = { runtime: {
              id: 'test', getManifest: () => ({}),
              sendNativeMessage: async (host, message) => {
                calls.push(message);
                const options = message.args[0];
                if (options.url.includes('unapproved.example')) return { value: { fallback: true } };
                return { value: { status: 201, statusText: '', headers: [['content-type', 'application/json'], ['x-server', 'yes']],
                                  body: btoa('{"ok":true}'), url: options.url, redirected: false } };
              }
            } };
            globalThis.fetch = async (input, init) => { normal.push([input, init]); return new Response('webkit'); };
            eval(bridge);
            const api = 'https://vault.example/api/config';
            const answer = await fetch(api, { credentials: 'omit', cache: 'no-store', headers: { 'Bitwarden-Client-Name': 'web', 'Device-Type': '9' } });
            const first = calls[0] && calls[0].args[0];
            const sentHeaders = new Map(first ? first.headers : []);
            const native = !!first && first.credentials === 'omit' && first.cache === 'no-store' && first.method === 'GET'
              && sentHeaders.get('bitwarden-client-name') === 'web' && sentHeaders.get('device-type') === '9';
            const answered = answer.status === 201 && answer.headers.get('x-server') === 'yes' && (await answer.json()).ok === true;
            await fetch(api, { credentials: 'omit', method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"a":1}' });
            await fetch(api, { credentials: 'omit' });
            const posted = calls.length === 3 && calls[1].args[0].body === '{"a":1}' && calls[1].args[0].method === 'POST'
              && calls[2].args[0].credentials === 'omit' && normal.length === 0;
            await fetch('https://unapproved.example/api', { credentials: 'omit', headers: { 'Device-Type': '9' } });
            const declined = calls.length === 4 && normal.length === 1;
            return { native, answered, posted, declined };
            """, arguments: ["bridge": ExtensionBridgeScript.source], in: nil, contentWorld: .page) as? [String: Any]
        let value = try #require(result)
        for key in ["native", "answered", "posted", "declined"] {
            #expect(value[key] as? Bool == true, "Failed: \(key)")
        }
    }

    @Test func siteAccessChoicesGrantWhatTheySay() throws {
        let required = try WKWebExtension.MatchPattern(string: "https://api.example/*")
        let optional: Set = [try WKWebExtension.MatchPattern(string: "*://*/*")]
        #expect(ExtensionHost.siteAccessPatterns(nil, approved: [required], optional: optional, sites: []) == [required])
        #expect(Set(ExtensionHost.siteAccessPatterns(.all, approved: [required], optional: optional, sites: [])) == optional.union([required]))
        #expect(ExtensionHost.siteAccessPatterns(.click, approved: [required], optional: optional, sites: ["bank.example"]).isEmpty)
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

    /// A blob: download names the extension that made it, so only that extension's own page is used to read it. A page's
    /// blob, or an ordinary address, names none.
    @Test func blobDownloadsKnowWhichExtensionMadeThem() throws {
        #expect(BridgeDownloads.blobOwner(try #require(URL(string: "blob:webkit-extension://abc/1234"))) == "abc")
        #expect(BridgeDownloads.blobOwner(try #require(URL(string: "blob:https://example.com/1234"))) == nil)
        #expect(BridgeDownloads.blobOwner(try #require(URL(string: "https://example.com/report.pdf"))) == nil)
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

    /// An extension allowed in private windows sees their downloads too, in its own profile only (#353).
    @Test func privateDownloadsOnlyToAnExtensionAllowedThere() {
        let other = UUID()
        let hidden = DownloadItem(filename: "c.pdf", sourceURL: nil, isPrivate: true)
        let everyday = DownloadItem(filename: "a.pdf", sourceURL: nil, isPrivate: false)
        #expect(BridgeDownloads.sees(hidden, in: Profile.defaultID, seesPrivate: true))
        #expect(!BridgeDownloads.sees(hidden, in: Profile.defaultID, seesPrivate: false))
        #expect(!BridgeDownloads.sees(hidden, in: other, seesPrivate: true))
        #expect(BridgeDownloads.sees(everyday, in: Profile.defaultID, seesPrivate: false))
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

/// The bridge's extensionFetch for a test extension page: host access as BridgeExtensionFetch checks it, then the
/// same routing, with a store of the test's own.
@MainActor
private final class HostAccessFetchDoor: NSObject, WKScriptMessageHandlerWithReply {
    let context: WKWebExtensionContext
    let store: WKWebsiteDataStore
    let requests = ExtensionFetchRequests()
    init(context: WKWebExtensionContext, store: WKWebsiteDataStore) { self.context = context; self.store = store }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let options = (body["args"] as? [Any])?.first as? [String: Any],
              let url = (options["url"] as? String).flatMap(URL.init(string:)) else { return replyHandler(nil, "Invalid request.") }
        guard BridgeExtensionFetch.allows(url, context: context) else { return replyHandler(["fallback": true], nil) }
        let context = context
        Task { @MainActor in
            do {
                let answer = try await requests.withHostAccess(options, url: url, extensionID: "test", store: store, keepsSameSiteCookies: { false },
                                                               authorize: { BridgeExtensionFetch.allows($0, context: context) })
                replyHandler(answer, nil)
            } catch { replyHandler(nil, (error as? BridgeError)?.message ?? "\(error)") }
        }
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
            let open = path == "/open" ? "Access-Control-Allow-Origin: *\r\n" : ""
            let signedIn = text.components(separatedBy: "\r\n").contains { $0.lowercased().hasPrefix("cookie:") && $0.contains("session=synthetic") }
            let body = path == "/binary" ? Data([0, 255, 128, 65])
                : path == "/echo" ? Data(bytes[boundary.upperBound..<(boundary.upperBound + length)])
                : path == "/headers" ? Data(text.utf8)
                : Data("{\"signedIn\":\(signedIn)}".utf8)
            let logoutOK = text.components(separatedBy: "\r\n").contains { $0.lowercased() == "origin: chrome-extension://test" }
                && text.components(separatedBy: "\r\n").contains { $0.lowercased().hasPrefix("cookie:") && $0.contains("logout_token=test-session") && !$0.contains("session=forged") }
            let status = redirect ? "302 Found" : path == "/logout" && !logoutOK ? "403 Forbidden" : "200 OK"
            let deleted = path == "/logout" ? "Set-Cookie: logout_token=; Max-Age=0; Path=/; HttpOnly\r\n" : ""
            let headers = redirect ? "Location: \(redirectTarget)\r\n" : open + deleted + "Set-Cookie: refreshed=synthetic; Path=/; SameSite=Lax; HttpOnly\r\n"
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
    /// Background WebSockets need local or granted hosts, never ones only asked for; wss://host counts as https://host.
    @Test func backgroundSocketsNeedHostAccess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Synthetic","version":"1.0","host_permissions":["https://named.example/*"],"optional_host_permissions":["https://push.example/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        #expect(!WebSocketBridge.allows(URL(string: "wss://named.example/socket")!, context: context))
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://named.example/*"))
        #expect(WebSocketBridge.allows(URL(string: "wss://named.example/socket")!, context: context))
        #expect(!WebSocketBridge.allows(URL(string: "wss://push.example/socket")!, context: context))
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://push.example/*"))
        #expect(WebSocketBridge.allows(URL(string: "wss://push.example/socket")!, context: context))
        // This Mac stays allowed with nothing asked, as it was before there was a local-receivers door: an extension
        // that already opened ws://localhost keeps working, and only its HTTP path goes through the new switch.
        for text in ["ws://localhost:8080/", "ws://127.0.0.1:1234/x", "ws://127.5.6.7/", "ws://[::1]:9000/", "wss://LOCALHOST./"] {
            #expect(WebSocketBridge.allows(URL(string: text)!, context: context))
        }
        for text in ["ws://push.example/socket", "wss://other.example/socket", "wss://push.example.evil.test/",
                     "wss://name:synthetic@push.example/", "https://push.example/socket", "ws://128.0.0.1/",
                     "ws://localhost.evil.test/", "ws://127.0.0.1.evil.test/", "ws://user:pw@localhost/", "http://localhost/"] {
            #expect(!WebSocketBridge.allows(URL(string: text)!, context: context), "\(text) is refused")
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

/// A tab WebKit can grant on a click, as Zigzag's tabs are, holding one web view.
@MainActor
private final class SiteAccessTestTab: NSObject, WKWebExtensionTab {
    let page: WKWebView
    init(_ page: WKWebView) { self.page = page }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { page }
    func url(for context: WKWebExtensionContext) -> URL? { page.url }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// Content scripts follow site access as it changes, the extension starting again when it has less, as ExtensionHost
/// does: On Click runs them only once clicked, while the tab stays on that site; On Specific Sites only
/// there; On All Sites everywhere.
@MainActor
struct SiteAccessContentScriptTests {
    @Test func lessAccessIsNarrowed() {
        #expect(ExtensionHost.narrowed(from: (["<all_urls>"], []), to: ([], [])))
        #expect(!ExtensionHost.narrowed(from: (["<all_urls>"], []), to: (["<all_urls>"], ["*://bank.example/*"])))
        #expect(ExtensionHost.narrowed(from: (["<all_urls>"], []), to: (["*://github.com/*"], ["*://bank.example/*"])))
        #expect(!ExtensionHost.narrowed(from: ([], []), to: (["<all_urls>"], [])))
        #expect(!ExtensionHost.narrowed(from: (["<all_urls>"], ["*://bank.example/*"]), to: (["<all_urls>"], [])))
    }

    @Test func contentScriptsFollowSiteAccess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0","content_scripts":[{"matches":["<all_urls>"],"js":["cs.js"],"run_at":"document_start"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.cs = 'ran';".utf8).write(to: folder.appendingPathComponent("cs.js"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        var context = WKWebExtensionContext(for: ext)
        let approved = Array(ext.allRequestedMatchPatterns)
        func apply(_ access: ExtensionInstalls.SiteAccess?, sites: [String] = []) throws {
            let before = ExtensionHost.access(of: context)
            ExtensionHost.applySiteAccess(access, approved: approved, sites: sites, offSites: [], approvesActiveTab: false, to: context)
            guard context.isLoaded, ExtensionHost.narrowed(from: before, to: ExtensionHost.access(of: context)) else { return }
            try controller.unload(context)
            context = WKWebExtensionContext(for: ext)
            ExtensionHost.applySiteAccess(access, approved: approved, sites: sites, offSites: [], approvesActiveTab: false, to: context)
            try controller.load(context)
        }
        try apply(nil)
        try controller.load(context)
        defer { try? controller.unload(context) }
        // Each page with its own configuration, as Zigzag's tabs have.
        func open(_ address: String, in page: WKWebView? = nil) async throws -> WKWebView {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = WKUserContentController()
            configuration.webExtensionController = controller
            let page = page ?? WKWebView(frame: .zero, configuration: configuration)
            page.loadHTMLString("<!doctype html><title>\(address)</title>", baseURL: URL(string: address)!)
            for _ in 0..<50 where page.isLoading || page.title != address { try await Task.sleep(for: .milliseconds(50)) }
            return page
        }
        func ran(_ page: WKWebView) async throws -> Bool {
            try await page.evaluateJavaScript("document.documentElement.dataset.cs === 'ran'") as? Bool ?? false
        }
        let local = "http://localhost:8123/", other = "http://127.0.0.1:8123/"

        #expect(try await ran(open(local)))
        #expect(try await ran(open(other)))
        try apply(.click)
        #expect(try await !ran(open(local)))
        #expect(try await !ran(open(other)))
        #expect(!context.hasAccess(to: URL(string: local)!))
        try apply(.sites, sites: ["localhost"])
        #expect(try await ran(open(local)))
        #expect(try await !ran(open(other)))
        try apply(.all)
        #expect(try await ran(open(local)))
        #expect(try await ran(open(other)))

        try apply(.click)
        let clicked = try await open(local)
        #expect(try await !ran(clicked))
        let tab = SiteAccessTestTab(clicked)
        controller.didOpenTab(tab)
        context.userGesturePerformed(in: tab)
        #expect(try await ran(clicked))
        #expect(context.hasAccess(to: URL(string: local)!, in: tab))
        #expect(!context.hasAccess(to: URL(string: local)!))
        // Another tab on the same site isn't given it, and the clicked one loses it once it leaves the site.
        // (macOS 27's WebKit still runs the clicked tab's content scripts in other tabs on that site meanwhile.)
        let second = SiteAccessTestTab(try await open(local))
        controller.didOpenTab(second)
        #expect(!context.hasAccess(to: URL(string: local)!, in: second))
        controller.didCloseTab(second, windowIsClosing: false)
        #expect(try await !ran(open(other, in: clicked)))
        #expect(!context.hasAccess(to: URL(string: other)!, in: tab))
        #expect(try await !ran(open(local, in: clicked)))
        #expect(!context.hasAccess(to: URL(string: local)!, in: tab))
        controller.didCloseTab(tab, windowIsClosing: false)
    }

    /// A site where extensions are off keeps their content scripts out at once, with the extension left running.
    @Test func anOffSiteNeedsNoRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0","content_scripts":[{"matches":["<all_urls>"],"js":["cs.js"],"run_at":"document_start"}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.cs = 'ran';".utf8).write(to: folder.appendingPathComponent("cs.js"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        let approved = Array(ext.allRequestedMatchPatterns)
        ExtensionHost.applySiteAccess(nil, approved: approved, sites: [], offSites: [], approvesActiveTab: false, to: context)
        try controller.load(context)
        defer { try? controller.unload(context) }
        func ran(_ address: String) async throws -> Bool {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController = WKUserContentController()
            configuration.webExtensionController = controller
            let page = WKWebView(frame: .zero, configuration: configuration)
            page.loadHTMLString("<!doctype html><title>\(address)</title>", baseURL: URL(string: address)!)
            for _ in 0..<50 where page.isLoading || page.title != address { try await Task.sleep(for: .milliseconds(50)) }
            return try await page.evaluateJavaScript("document.documentElement.dataset.cs === 'ran'") as? Bool ?? false
        }
        let off = "http://localhost:8123/", other = "http://127.0.0.1:8123/"
        #expect(try await ran(off))
        let before = ExtensionHost.access(of: context)
        ExtensionHost.applySiteAccess(nil, approved: approved, sites: [], offSites: ["localhost"], approvesActiveTab: false, to: context)
        #expect(!ExtensionHost.narrowed(from: before, to: ExtensionHost.access(of: context)))
        #expect(context.isLoaded && controller.extensionContexts.contains(context))
        #expect(try await !ran(off))
        #expect(try await ran(other))
        ExtensionHost.applySiteAccess(nil, approved: approved, sites: [], offSites: [], approvesActiveTab: false, to: context)
        #expect(try await ran(off))
    }

    /// Under On Click, an extension that never asked for activeTab is given only a site it asked for.
    @Test func aClickGivesOnlyASiteItAskedFor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0","host_permissions":["https://github.com/*"],"optional_host_permissions":["https://later.example/*"]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        #expect(ExtensionHost.asksFor(URL(string: "https://github.com/x"), in: ext))
        #expect(ExtensionHost.asksFor(URL(string: "https://later.example/"), in: ext))
        #expect(!ExtensionHost.asksFor(URL(string: "https://bank.example/"), in: ext))
        #expect(!ExtensionHost.asksFor(nil, in: ext))
    }
}

extension ExtensionBridgeTests {
    /// tabs.query lists every space's tabs in a window, this space's first, as Chrome lists every tab in a window;
    /// the active one is the one the window gives, even with nothing open in the space in front.
    @available(macOS 15.4, *)
    @Test func extensionsListTabsOfEverySpaceInTheWindow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0","permissions":["tabs"]}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))

        let before = Library.shared.snapshot
        defer { Library.shared.restore(before) }
        let home = Library.shared.spaces[0].id
        let work = Library.shared.addSpace(name: "Tabs query").id
        let manager = TabManager(spaceID: home)
        defer { manager.invalidate() }
        let first = Tab(url: URL(string: "https://one.example/"), title: "One", spaceID: home)
        let second = Tab(url: URL(string: "https://two.example/"), title: "Two", spaceID: home)
        let away = Tab(url: URL(string: "https://away.example/"), title: "Away", spaceID: work)
        manager.adopt([first, second], in: home)
        manager.adopt([away], in: work)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { controller.window?.close() }
        manager.select(second)
        // Loaded with the tabs' profile's extensions, so they're its to see.
        let extensions = first.profile.extensions.controller
        try extensions.load(context)
        defer { try? extensions.unload(context) }

        let listed = { controller.tabs(for: context).compactMap { $0 as? Tab } }
        #expect(listed().map(\.displayTitle) == ["One", "Two", "Away"])
        #expect(away.window(for: context) === controller)
        #expect(away.indexInWindow(for: context) == 2)
        #expect(second.isSelected(for: context) && !first.isSelected(for: context) && !away.isSelected(for: context))

        // In the other space, its tabs come first and its tab is the active one.
        manager.switchToSpace(work)
        manager.select(away)
        #expect(listed().map(\.displayTitle) == ["Away", "One", "Two"])
        #expect(away.isSelected(for: context) && !second.isSelected(for: context))

        // A space with nothing open: the window's active tab is the one left selected elsewhere, and a query finds it.
        let empty = Library.shared.addSpace(name: "Tabs query empty").id
        manager.switchToSpace(empty)
        #expect(listed().count == 3)
        let active = try #require(controller.activeTab(for: context) as? Tab)
        #expect(listed().filter { $0.isSelected(for: context) }.map(ObjectIdentifier.init) == [ObjectIdentifier(active)])

        // A private window stays hidden from an extension not allowed there.
        let hidden = TabManager(spaceID: home, isPrivate: true)
        defer { hidden.invalidate() }
        hidden.adopt([Tab(url: URL(string: "https://private.example/"), title: "Private", spaceID: home)], in: home)
        let privateWindow = BrowserWindowController(tabManager: hidden, frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { privateWindow.window?.close() }
        #expect(!context.hasAccessToPrivateData)
        #expect(privateWindow.tabs(for: context).isEmpty)
        #expect(privateWindow.activeTab(for: context) == nil)
        // Allowed there, it lists them.
        context.hasAccessToPrivateData = true
        #expect(privateWindow.tabs(for: context).compactMap { ($0 as? Tab)?.displayTitle } == ["Private"])
    }
}

/// A large content script for many sites is held once, not once per site, and still runs once where it matches (#485).
@MainActor
struct ContentScriptCopiesTests {
    private static func footprint() -> Int64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : 0
    }

    @Test func aLargeScriptForManySitesIsHeldOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sites = (0..<60).map { "http://site\($0).example/*" } + ["http://localhost/*"]
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Probe", "version": "1.0",
                                       "content_scripts": [["matches": sites, "js": ["cs.js"], "run_at": "document_start"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        // About 1 MB, with a character outside Latin-1 so WebKit holds it as UTF-16, as uBlacklist's is.
        let padding = String(repeating: "var padding = 'padding padding padding padding padding padding';\n", count: 16_000)
        let script = "// \u{2014}\n" + padding + "document.documentElement.dataset.cs = String(Number(document.documentElement.dataset.cs || 0) + 1);"
        try Data(script.utf8).write(to: folder.appendingPathComponent("cs.js"))
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        ExtensionHost.applySiteAccess(nil, approved: Array(ext.allRequestedMatchPatterns), sites: [], offSites: [], approvesActiveTab: false, to: context)
        #expect(context.grantedPermissionMatchPatterns.count == sites.count)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        configuration.webExtensionController = controller
        let page = WKWebView(frame: .zero, configuration: configuration)
        func load() async throws -> String? {
            page.loadHTMLString("<!doctype html><title>t</title>", baseURL: URL(string: "http://localhost:8123/")!)
            for _ in 0..<100 where page.isLoading || page.title != "t" { try await Task.sleep(for: .milliseconds(50)) }
            return try await page.evaluateJavaScript("document.documentElement.dataset.cs || ''") as? String
        }
        // The page's process is running before the extension loads, as a restored tab's is at launch.
        _ = try await load()
        let before = Self.footprint()
        try controller.load(context)
        defer { try? controller.unload(context) }
        var runs: String?
        for _ in 0..<40 {
            runs = try await load()
            if runs == "1" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(runs == "1")
        // One copy per granted site would be about 120 MB.
        let grown = Self.footprint() - before
        #expect(grown < 40_000_000, "grew \(grown / 1_000_000) MB")
    }
}

/// chrome.sessions lists what History › Recently Closed brings back (#486).
@MainActor
struct ExtensionSessionsTests {
    private let mine = UUID(), other = UUID()
    private let home = UUID(), away = UUID()

    private func closed(_ title: String, at seconds: TimeInterval, space: UUID? = nil, url: String? = "https://example.com/") -> TabManager.ClosedTab {
        TabManager.ClosedTab(url: url.flatMap(URL.init(string:)), title: title, spaceID: space ?? home, index: 3, interactionState: nil,
                             closedAt: Date(timeIntervalSince1970: seconds))
    }

    private func window(space: UUID, pages: [String]) -> SessionState.WindowState {
        let tabs = pages.map { SessionState.TabState(id: UUID(), url: URL(string: "https://\($0).example/"), title: $0,
                                                     lastActivated: Date(), createdAt: Date()) }
        return SessionState.WindowState(frame: [0, 0, 800, 600], sidebarVisible: true, sidebarWidth: 240, currentSpaceID: space,
                                        spaces: [SessionState.SpaceTabs(spaceID: space, tabs: tabs, selectedTabID: tabs.first?.id)], bookmarkTabs: [])
    }

    private func profileOf(_ space: UUID) -> UUID { space == home ? mine : other }

    @Test func newestFirstOnlyThisProfilesAndOnlyPages() {
        let a = closed("A", at: 100), b = closed("B", at: 300), elsewhere = closed("Elsewhere", at: 400, space: away)
        let blank = closed("Blank", at: 500, url: nil)
        let windowID = UUID()
        let entries = BridgeSessions.mine(tabs: [a, b, elsewhere, blank, a],
                                          windows: [(windowID, window(space: home, pages: ["one", "two"]), Date(timeIntervalSince1970: 200)),
                                                    (UUID(), window(space: away, pages: ["three"]), Date(timeIntervalSince1970: 600))],
                                          profile: mine, profileOf: profileOf)
        let sessions = BridgeSessions.recentlyClosed(entries, maxResults: nil).map(BridgeSessions.session)
        #expect(sessions.map { $0["lastModified"] as? Int } == [300, 200, 100])
        let tab = sessions[0]["tab"] as? [String: Any]
        #expect(tab?["sessionId"] as? String == "t:\(b.id)")
        #expect(tab?["title"] as? String == "B")
        #expect(tab?["url"] as? String == "https://example.com/")
        #expect(tab?["index"] as? Int == 3)
        #expect(tab?["incognito"] as? Bool == false)
        let shown = sessions[1]["window"] as? [String: Any]
        #expect(shown?["sessionId"] as? String == "w:\(windowID)")
        #expect((shown?["tabs"] as? [[String: Any]])?.map { $0["title"] as? String } == ["one", "two"])
        #expect((shown?["tabs"] as? [[String: Any]])?.map { $0["index"] as? Int } == [0, 1])
        #expect(JSONSerialization.isValidJSONObject(sessions))
    }

    @Test func maxResultsDefaultsToAndStopsAt25() {
        let entries = (0..<40).map { BridgeSessions.Entry.tab(closed("\($0)", at: TimeInterval($0))) }
        #expect(BridgeSessions.recentlyClosed(entries, maxResults: nil).count == 25)
        #expect(BridgeSessions.recentlyClosed(entries, maxResults: 100).count == 25)
        #expect(BridgeSessions.recentlyClosed(entries, maxResults: -1).isEmpty)
        #expect(BridgeSessions.recentlyClosed(entries, maxResults: 3).map { BridgeSessions.session($0)["lastModified"] as? Int } == [39, 38, 37])
    }

    @Test func aTieGoesToTheOneClosedLater() {
        let first = closed("First", at: 100), second = closed("Second", at: 100)
        #expect(BridgeSessions.newestFirst([.tab(first), .tab(second)]).map(\.sessionID) == ["t:\(second.id)", "t:\(first.id)"])
    }

    @Test func needsTheSessionsPermission() {
        #expect(BridgeSessions.permission == "sessions")
        #expect(ExtensionBridge.handlerNames.contains("sessions"))
        #expect(ExtensionBridgeScript.permissions.contains("sessions"))
        let now = Date()
        let granted = [WKWebExtension.Permission(rawValue: "sessions"): now.addingTimeInterval(60)]
        #expect(ExtensionBridge.allows("sessions", declared: (["sessions"], []), granted: granted, now: now))
        #expect(!ExtensionBridge.allows("sessions", declared: ([], []), granted: granted, now: now))
        #expect(!ExtensionBridge.allows("sessions", declared: (["sessions"], []), granted: [:], now: now))
    }

    @Test func aPrivateWindowsClosingTellsNoOne() {
        var heard = 0
        let token = WindowManager.recentlyClosedChanged.observe { heard += 1 }
        defer { token.cancel() }
        let secret = TabStore(isPrivate: true)
        secret.closedTabs.append(closed("Private", at: 100))
        #expect(heard == 0)
        let everyday = TabStore()
        everyday.closedTabs.append(closed("Everyday", at: 100))
        #expect(heard == 1)
    }
}

/// bookmarks.onChildrenReordered fires for a sort-like reorder, not a single move (#487).
struct BookmarkReorderTests {
    @Test func aSortIsAReorder() {
        let sorted = BridgeBookmarks.reordered(before: ["s:1": ["d", "c", "b", "a"], "s:2": ["x", "y"]],
                                               after: ["s:1": ["a", "b", "c", "d"], "s:2": ["x", "y"]])
        #expect(sorted.map(\.parent) == ["s:1"])
        #expect(sorted.first?.childIds == ["a", "b", "c", "d"])
    }

    @Test func oneMoveAddOrRemoveIsNot() {
        #expect(BridgeBookmarks.reordered(before: ["1": ["a", "b", "c"]], after: ["1": ["b", "a", "c"]]).isEmpty)
        #expect(BridgeBookmarks.reordered(before: ["1": ["c", "a", "b"]], after: ["1": ["a", "b", "c"]]).isEmpty)
        #expect(BridgeBookmarks.reordered(before: ["1": ["a", "b", "c"]], after: ["1": ["c", "b", "a", "d"]]).isEmpty)
        #expect(BridgeBookmarks.reordered(before: ["1": ["a", "b", "c"]], after: ["1": ["c", "a"]]).isEmpty)
        #expect(BridgeBookmarks.reordered(before: [:], after: ["1": ["b", "a", "c"]]).isEmpty)
        #expect(BridgeBookmarks.isOneMove(["a", "b", "c", "d"], ["b", "c", "d", "a"]))
        #expect(!BridgeBookmarks.isOneMove(["a", "b", "c", "d"], ["b", "a", "d", "c"]))
    }

    @MainActor @Test func anImportIsBracketed() {
        let library = Library.shared, profile = UUID()
        var heard: [(started: Bool, profile: UUID)] = []
        let token = library.bookmarkImport.observe { heard.append($0) }
        defer { token.cancel() }
        let value = library.importing(into: profile) { () -> Int in
            #expect(heard.map(\.started) == [true])
            return 7
        }
        #expect(value == 7)
        #expect(heard.map(\.started) == [true, false])
        #expect(heard.allSatisfy { $0.profile == profile })
    }
}

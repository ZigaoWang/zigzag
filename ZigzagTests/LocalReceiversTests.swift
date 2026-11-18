import Foundation
import Testing
@testable import Zigzag

@Suite("LocalReceivers")
struct LocalReceiversTests {
    private let page = "https://creator.zerowork.io"
    private var site: LocalReceivers.Identity { .site(origin: page) }
    private var answerURL: URL { URL(string: "http://localhost:9990/callback")! }

    @Test func onlyThisMacIsLoopback() {
        for address in ["http://localhost:9990", "http://app.localhost:9990/x", "http://127.0.0.1:9990",
                        "http://127.42.0.9:1", "ws://[::1]:9990", "http://localhost.:9990"] {
            #expect(LocalReceivers.isLoopback(URL(string: address)!), "\(address) is this Mac")
        }
        for address in ["https://example.com", "http://192.168.1.1", "http://10.0.0.1",
                        "http://127.0.0.1.example.com", "http://localhost.example.com",
                        "https://localhost:9990", "wss://localhost:9990"] {
            #expect(!LocalReceivers.isLoopback(URL(string: address)!), "\(address) is not caught")
        }
    }

    @Test func aJSONPostAsksTheHelperFirst() {
        let post = LocalReceivers.Request(url: answerURL, method: "POST",
                                          headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        #expect(LocalReceivers.needsPreflight(post))
        #expect(LocalReceivers.preflightHeaderNames(post) == ["content-type"])

        let form = LocalReceivers.Request(url: answerURL, method: "POST",
                                          headers: ["Content-Type": "application/x-www-form-urlencoded; charset=utf-8"],
                                          body: Data("a=1".utf8))
        #expect(!LocalReceivers.needsPreflight(form))

        let plain = LocalReceivers.Request(url: answerURL, headers: ["Accept": "application/json"])
        #expect(!LocalReceivers.needsPreflight(plain))

        let token = LocalReceivers.Request(url: answerURL, headers: ["X-Token": "secret"])
        #expect(LocalReceivers.needsPreflight(token))
        #expect(LocalReceivers.preflightHeaderNames(token) == ["x-token"])
    }

    @Test func aCallerPresentsItsOwnOrigin() {
        var spoofed = LocalReceivers.Request(url: answerURL)
        spoofed.headers["Origin"] = "https://evil.example"
        let built = LocalReceivers.urlRequest(for: spoofed, as: site)
        #expect(built.value(forHTTPHeaderField: "Origin") == page)
        #expect(built.value(forHTTPHeaderField: "Sec-Fetch-Site") == "cross-site")
        #expect(built.value(forHTTPHeaderField: "Sec-Fetch-Mode") == "cors")
        #expect(built.value(forHTTPHeaderField: "Referer") == page + "/")

        let extensionRequest = LocalReceivers.urlRequest(for: spoofed, as: .webExtension(id: "abc123"))
        #expect(extensionRequest.value(forHTTPHeaderField: "Origin") == "chrome-extension://abc123")
        #expect(extensionRequest.value(forHTTPHeaderField: "Sec-Fetch-Site") == "none")
        #expect(extensionRequest.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test func aReplyMustAllowTheCaller() {
        let request = LocalReceivers.Request(url: answerURL)
        let other = LocalReceivers.Response(url: answerURL, status: 200,
                                            headers: ["access-control-allow-origin": "https://other.example"], body: Data())
        #expect(!LocalReceivers.allowsRead(other, for: request, as: site))

        let own = LocalReceivers.Response(url: answerURL, status: 200,
                                          headers: ["access-control-allow-origin": page], body: Data())
        #expect(LocalReceivers.allowsRead(own, for: request, as: site))

        let none = LocalReceivers.Response(url: answerURL, status: 200, headers: [:], body: Data())
        #expect(!LocalReceivers.allowsRead(none, for: request, as: site))
    }

    @Test func aStarDoesNotStandForCookies() {
        let request = LocalReceivers.Request(url: answerURL)
        let star = LocalReceivers.Response(url: answerURL, status: 200,
                                           headers: ["access-control-allow-origin": "*"], body: Data())
        #expect(LocalReceivers.allowsRead(star, for: request, as: site))

        var withCookies = request
        withCookies.credentials = .include
        #expect(!LocalReceivers.allowsRead(star, for: withCookies, as: site))

        let named = LocalReceivers.Response(url: answerURL, status: 200,
                                            headers: ["access-control-allow-origin": page,
                                                      "access-control-allow-credentials": "true"], body: Data())
        #expect(LocalReceivers.allowsRead(named, for: withCookies, as: site))

        let namedWithoutPermission = LocalReceivers.Response(url: answerURL, status: 200,
                                                             headers: ["access-control-allow-origin": page],
                                                             body: Data())
        #expect(!LocalReceivers.allowsRead(namedWithoutPermission, for: withCookies, as: site))
    }

    @Test func aPreflightMustAllowTheMethodAndHeaders() {
        let post = LocalReceivers.Request(url: answerURL, method: "POST",
                                          headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        let allowed = LocalReceivers.Response(url: answerURL, status: 204,
                                              headers: ["access-control-allow-origin": page,
                                                        "access-control-allow-methods": "POST",
                                                        "access-control-allow-headers": "content-type"], body: Data())
        #expect(LocalReceivers.allowsPreflight(allowed, for: post, as: site))

        let wrongMethod = LocalReceivers.Response(url: answerURL, status: 204,
                                                  headers: ["access-control-allow-origin": page,
                                                            "access-control-allow-methods": "GET",
                                                            "access-control-allow-headers": "content-type"],
                                                  body: Data())
        #expect(!LocalReceivers.allowsPreflight(wrongMethod, for: post, as: site))

        let missingHeader = LocalReceivers.Response(url: answerURL, status: 204,
                                                    headers: ["access-control-allow-origin": page,
                                                              "access-control-allow-methods": "POST"],
                                                    body: Data())
        #expect(!LocalReceivers.allowsPreflight(missingHeader, for: post, as: site))

        let refused = LocalReceivers.Response(url: answerURL, status: 403,
                                              headers: ["access-control-allow-origin": page,
                                                        "access-control-allow-methods": "POST",
                                                        "access-control-allow-headers": "content-type"],
                                              body: Data())
        #expect(!LocalReceivers.allowsPreflight(refused, for: post, as: site))
    }

    @Test func anExtensionIsNotHeldToCORS() {
        let extensionIdentity = LocalReceivers.Identity.webExtension(id: "abc123")
        let bare = LocalReceivers.Response(url: answerURL, status: 200, headers: [:], body: Data())
        #expect(LocalReceivers.allowsRead(bare, for: LocalReceivers.Request(url: answerURL), as: extensionIdentity))
        #expect(LocalReceivers.allowsPreflight(bare, for: LocalReceivers.Request(url: answerURL), as: extensionIdentity))
    }

    @Test func aNativeRequestSendsThePreflightAndTheCall() async throws {
        let recorder = Recorder()
        let transport: LocalReceivers.Transport = { request in
            await recorder.record(request)
            if request.httpMethod == "OPTIONS" {
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1",
                                                headerFields: ["Access-Control-Allow-Origin": self.page,
                                                               "Access-Control-Allow-Methods": "POST",
                                                               "Access-Control-Allow-Headers": "content-type"])!)
            }
            return (Data(#"{"ok":true}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Access-Control-Allow-Origin": self.page])!)
        }
        let post = LocalReceivers.Request(url: answerURL, method: "POST",
                                          headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        let answer = try await LocalReceivers.send(post, as: site, transport: transport)
        #expect(answer.status == 200)
        #expect(String(data: answer.body, encoding: .utf8) == #"{"ok":true}"#)

        let requests = await recorder.all()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "OPTIONS")
        #expect(requests[0].value(forHTTPHeaderField: "Origin") == page)
        #expect(requests[0].value(forHTTPHeaderField: "Access-Control-Request-Method") == "POST")
        #expect(requests[0].value(forHTTPHeaderField: "Access-Control-Request-Headers") == "content-type")
        #expect(requests[1].httpMethod == "POST")
        #expect(requests[1].value(forHTTPHeaderField: "Origin") == page)
    }

    @Test func aReplyThatDoesNotAllowTheCallerFails() async {
        let transport: LocalReceivers.Transport = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                     headerFields: ["Access-Control-Allow-Origin": "https://other.example"])!)
        }
        let answer = LocalReceivers.Request(url: answerURL)
        await expect(.cors("the helper's reply does not allow \(page)")) {
            _ = try await LocalReceivers.send(answer, as: site, transport: transport)
        }
    }

    @Test func aRedirectOffThisMacIsRefused() async {
        let transport: LocalReceivers.Transport = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                     headerFields: ["Location": "https://example.com/"])!)
        }
        let answer = LocalReceivers.Request(url: answerURL)
        await expect(.refused("the helper redirected off this Mac")) {
            _ = try await LocalReceivers.send(answer, as: site, transport: transport)
        }
    }

    @Test func anAddressThatIsNotLoopbackNeverLeaves() async {
        let recorder = Recorder()
        let transport: LocalReceivers.Transport = { request in
            await recorder.record(request)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: [:])!)
        }
        let elsewhere = LocalReceivers.Request(url: URL(string: "https://example.com/")!)
        await expect(.notLoopback) {
            _ = try await LocalReceivers.send(elsewhere, as: site, transport: transport)
        }
        #expect(await recorder.all().isEmpty)
    }

    private func expect(_ failure: LocalReceivers.Failure, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("the request was not refused")
        } catch let thrown as LocalReceivers.Failure {
            #expect(thrown == failure)
        } catch {
            Issue.record("an unexpected failure: \(error)")
        }
    }
}

private actor Recorder {
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) { requests.append(request) }
    func all() -> [URLRequest] { requests }
}

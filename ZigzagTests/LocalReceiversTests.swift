import Foundation
import Testing
import WebKit
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

    @Test func theSiteDoorNeedsBothSwitches() {
        let name = "LocalReceiversTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        let master = LocalReceivers.isEnabled
        // The switch is put back before the store is: writing it after would land in the real defaults.
        defer {
            LocalReceivers.isEnabled = master
            SitePermissions.defaults = before
            defaults.removeScratchSuite(name)
        }
        let origin = "https://creator.zerowork.io"

        LocalReceivers.isEnabled = false
        SitePermissions.setLocalReceivers(true, origin: origin)
        #expect(!LocalReceivers.allowsSite(origin: origin), "off for every site, even where the site said yes")

        LocalReceivers.isEnabled = true
        #expect(LocalReceivers.allowsSite(origin: origin))

        SitePermissions.setLocalReceivers(false, origin: origin)
        #expect(!LocalReceivers.allowsSite(origin: origin))
    }

    /// A helper must not be able to move a call off this Mac with a redirect. The transport refuses to follow one,
    /// so what comes back is the helper's 302 itself, and that is refused before its body reaches anyone.
    @Test func aRedirectIsRefusedRatherThanFollowed() async {
        let url = answerURL
        let sent: @Sendable (String) -> (Data, URLResponse) = { location in
            (Data(), HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": location])!)
        }
        await expect(.refused("the helper redirected off this Mac")) {
            _ = try await LocalReceivers.send(LocalReceivers.Request(url: url), as: site,
                                              transport: { _ in sent("http://192.168.1.20/steal") })
        }
        // One that stays on this Mac is refused too: the door answers where it is, never by following.
        await expect(.refused("the helper redirected")) {
            _ = try await LocalReceivers.send(LocalReceivers.Request(url: url), as: site,
                                              transport: { _ in sent("http://localhost:9990/elsewhere") })
        }
    }

    /// The whole door is shut while the Settings switch is off, whatever a site was allowed before.
    @Test func theMasterSwitchShutsEverySiteDoor() {
        let name = "LocalReceiversTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        let master = LocalReceivers.isEnabled
        // Restore the store first, then the switch: writing through the suite after restoring it is what leaked
        // into the real defaults before.
        defer {
            LocalReceivers.isEnabled = master
            SitePermissions.defaults = before
            defaults.removeScratchSuite(name)
        }
        let origin = "https://creator.zerowork.io"
        SitePermissions.setLocalReceivers(true, origin: origin)
        LocalReceivers.isEnabled = false
        #expect(!LocalReceiverShim.serves(origin: origin))
        LocalReceivers.isEnabled = true
        #expect(LocalReceiverShim.serves(origin: origin))
        #expect(!LocalReceiverShim.serves(origin: "https://elsewhere.example"))
    }

    /// A page that isn't allowed keeps WebKit's own fetch, XHR and WebSocket: its own dev server works as before.
    @Test func aPageWithoutItsSwitchGetsTheScriptOnlyWhenAllowed() {
        let name = "LocalReceiversTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        let master = LocalReceivers.isEnabled
        defer {
            LocalReceivers.isEnabled = master
            SitePermissions.defaults = before
            defaults.removeScratchSuite(name)
        }
        let allowed = "https://creator.zerowork.io"
        let localhostPage = "http://localhost:3000"
        LocalReceivers.isEnabled = true
        SitePermissions.setLocalReceivers(true, origin: allowed)
        #expect(LocalReceiverShim.serves(origin: allowed))
        #expect(!LocalReceiverShim.serves(origin: localhostPage), "a local dev page keeps its own fetch and HMR socket")
        LocalReceivers.isEnabled = false
        #expect(!LocalReceiverShim.serves(origin: allowed))
    }

    @Test func theSiteDoorIsOffUntilItIsTurnedOn() {
        let name = "LocalReceiversTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        let master = LocalReceivers.isEnabled
        // The switch is put back before the store is: writing it after would land in the real defaults.
        defer {
            LocalReceivers.isEnabled = master
            SitePermissions.defaults = before
            defaults.removeScratchSuite(name)
        }
        #expect(!LocalReceivers.isEnabled)
        LocalReceivers.isEnabled = true
        #expect(LocalReceivers.isEnabled)
        LocalReceivers.isEnabled = false
    }

    // MARK: Leaving a site

    /// The script names the origin it was put in for, and installs nowhere else: one left in a tab that has moved on,
    /// or handed to a page opened for another, leaves that page's own fetch, XHR and WebSocket alone.
    @MainActor @Test func theScriptIsForOneOriginOnly() {
        let script = LocalReceiverShim.source(for: "https://creator.zerowork.io")
        #expect(script.contains("if (location.origin !== \"https://creator.zerowork.io\") return;"))
        #expect(script != LocalReceiverShim.source(for: "http://localhost:3000"))
        #expect(script.hasPrefix("/* zigzag local receivers */"))
    }

    /// A tab that leaves the site it was allowed on has the script and the handler taken out before the next page
    /// starts, and a private tab never gets either. Going to another allowed site swaps the script rather than
    /// piling one up per site.
    @MainActor @Test func leavingAnAllowedSiteTakesTheDoorOut() {
        let name = "LocalReceiversTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        let master = LocalReceivers.isEnabled
        defer {
            LocalReceivers.isEnabled = master
            SitePermissions.defaults = before
            defaults.removeScratchSuite(name)
        }
        let first = "https://creator.zerowork.io"
        let second = "https://second.example"
        LocalReceivers.isEnabled = true
        SitePermissions.setLocalReceivers(true, origin: first)
        SitePermissions.setLocalReceivers(true, origin: second)

        let controller = WKUserContentController()
        LocalReceiverShim.sync(controller: controller, tab: nil, origin: first, isPrivate: false)
        #expect(controller.userScripts.count == 1, "the allowed site gets the door")

        // Another allowed site: one script, for the page that is coming, not one per site visited.
        LocalReceiverShim.sync(controller: controller, tab: nil, origin: second, isPrivate: false)
        #expect(controller.userScripts.count == 1)
        #expect(controller.userScripts.first?.source == LocalReceiverShim.source(for: second))

        // A site without its switch: nothing of the door is left in the tab.
        LocalReceiverShim.sync(controller: controller, tab: nil, origin: "https://elsewhere.example", isPrivate: false)
        #expect(controller.userScripts.isEmpty)

        // A private tab keeps WebKit's own networking, even where the site is allowed.
        LocalReceiverShim.sync(controller: controller, tab: nil, origin: first, isPrivate: true)
        #expect(controller.userScripts.isEmpty)
    }

    /// A page can post to the handler directly, so the door itself refuses what WebKit's fetch would never send.
    @Test func aMalformedRequestNeverLeaves() async {
        #expect(LocalReceivers.isWellFormed(LocalReceivers.Request(url: answerURL, method: "POST", headers: ["X-Token": "abc"])))
        #expect(!LocalReceivers.isWellFormed(LocalReceivers.Request(url: answerURL, method: "GET\r\nX: y", headers: [:])))
        #expect(!LocalReceivers.isWellFormed(LocalReceivers.Request(url: answerURL, method: "TRACE", headers: [:])))
        #expect(!LocalReceivers.isWellFormed(LocalReceivers.Request(url: answerURL, headers: ["Origin ": "https://evil.example"])))
        #expect(!LocalReceivers.isWellFormed(LocalReceivers.Request(url: answerURL, headers: ["X-A": "1\r\nOrigin: https://evil.example"])))
        await expect(.refused("the request is malformed")) {
            _ = try await LocalReceivers.send(LocalReceivers.Request(url: answerURL, headers: ["X-A": "1\nB: 2"]), as: site,
                                              transport: { _ in Issue.record("sent"); throw URLError(.cancelled) })
        }
    }

    /// The ports browsers never load from stay shut through the door, for sites and extensions alike.
    @Test func aBlockedPortNeverLeaves() async {
        #expect(LocalReceivers.blockedPort(of: URL(string: "http://localhost:25/")!) == 25)
        #expect(LocalReceivers.blockedPort(of: URL(string: "ws://127.0.0.1:6667/")!) == 6667)
        #expect(LocalReceivers.blockedPort(of: URL(string: "http://localhost/")!) == nil)
        #expect(LocalReceivers.blockedPort(of: URL(string: "http://localhost:6379/")!) == nil, "not on the spec's list")
        for identity in [site, LocalReceivers.Identity.webExtension(id: "abc")] {
            await expect(.blockedPort(587)) {
                _ = try await LocalReceivers.send(LocalReceivers.Request(url: URL(string: "http://localhost:587/")!), as: identity,
                                                  transport: { _ in Issue.record("sent"); throw URLError(.cancelled) })
            }
        }
        #expect(LocalReceivers.Failure.blockedPort(22).errorDescription == "Port 22 is blocked, as browsers block it.")
    }

    /// A site's call is cross-site: SameSite cookies stay behind, as WebKit leaves them; an extension's carry them.
    @Test func aSiteCallLeavesSameSiteCookiesBehind() throws {
        func cookie(_ name: String, sameSite: HTTPCookieStringPolicy?) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "1", .domain: "localhost", .path: "/"]
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            return try #require(HTTPCookie(properties: properties))
        }
        let cookies = [try cookie("none", sameSite: nil), try cookie("lax", sameSite: .sameSiteLax),
                       try cookie("strict", sameSite: .sameSiteStrict)]
        #expect(LocalReceivers.sendable(cookies, to: answerURL, crossSite: true).map(\.name) == ["none"])
        #expect(LocalReceivers.sendable(cookies, to: answerURL, crossSite: false).map(\.name) == ["none", "lax", "strict"])
    }

    /// The helper's cookies are never the page's to read, even when it lists them as exposed.
    @MainActor @Test func aPageNeverReadsTheHelpersCookies() {
        let answer = LocalReceivers.Response(url: answerURL, status: 200,
                                             headers: ["content-type": "text/plain", "set-cookie": "s=1", "x-id": "7",
                                                       "access-control-expose-headers": "Set-Cookie, X-Id"],
                                             body: Data())
        let headers = (LocalReceiverMessages.reply(answer, to: LocalReceivers.Request(url: answerURL))["headers"] as? [[String]]) ?? []
        let names = Set(headers.map { $0[0] })
        #expect(names.contains("x-id"))
        #expect(names.contains("content-type"))
        #expect(!names.contains("set-cookie"))
    }

    /// Leaving an allowed site ends the sockets its page opened, before the next page can hear from them.
    @MainActor @Test func leavingAnAllowedSiteEndsItsSockets() {
        let name = "LocalReceiversTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        let master = LocalReceivers.isEnabled
        defer {
            LocalReceivers.isEnabled = master
            SitePermissions.defaults = before
            defaults.removeScratchSuite(name)
        }
        let allowed = "https://creator.zerowork.io"
        LocalReceivers.isEnabled = true
        SitePermissions.setLocalReceivers(true, origin: allowed)

        let controller = WKUserContentController()
        let messages = LocalReceiverMessages(tab: Tab(url: nil, spaceID: UUID()))
        messages.track(LocalReceiverSocket(id: "a", url: URL(string: "ws://127.0.0.1:9")!, protocols: [], origin: allowed,
                                           webView: nil, reply: { _, _ in }), id: "a")
        #expect(messages.openSocketCount == 1)
        let left = LocalReceiverShim.sync(controller: controller, tab: nil, origin: "https://elsewhere.example",
                                          isPrivate: false, current: messages)
        #expect(left == nil)
        #expect(messages.openSocketCount == 0)
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

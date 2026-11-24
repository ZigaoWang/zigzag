import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A cookie store that keeps what it's given, slowly when asked to.
@MainActor
private final class FakeJar: SessionCookieJar {
    var cookies: [HTTPCookie] = []
    var delay: Duration = .zero

    func setSessionCookies(_ cookies: [HTTPCookie]) async {
        if delay > .zero { try? await Task.sleep(for: delay) }
        self.cookies += cookies
    }
}

@MainActor
@Suite(.serialized)
struct SessionCookiesTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SessionCookiesTests-\(UUID().uuidString)", isDirectory: true)
    private var url: URL { SessionCookies.file(in: folder) }

    private func cookie(_ name: String, domain: String, expires: Date? = nil, secure: Bool = false, httpOnly: Bool = false,
                        sameSite: HTTPCookieStringPolicy? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v-\(name)", .domain: domain, .path: "/"]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = sameSite.rawValue }
        return HTTPCookie(properties: properties)!
    }

    private func save(_ cookies: [HTTPCookie]) {
        let chosen = SessionCookies.toSave(cookies)
        SessionCookies.write(chosen.isEmpty ? nil : SessionCookies.encode(chosen), to: url)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func onlySessionCookiesComeBackAsTheyWere() async throws {
        defer { cleanUp() }
        save([cookie("wide", domain: ".youtube.com", secure: true, httpOnly: true, sameSite: .sameSiteLax),
              cookie("kept", domain: "example.com", expires: Date().addingTimeInterval(86_400))])
        let jar = FakeJar()
        let count = await SessionCookies.restore(from: url, into: jar)
        #expect(count == 1)
        #expect(jar.cookies.count == 1)
        let back = try #require(jar.cookies.first)
        #expect(back.name == "wide" && back.value == "v-wide" && back.domain == ".youtube.com" && back.path == "/")
        #expect(back.isSessionOnly && back.isSecure && back.isHTTPOnly && back.sameSitePolicy == .sameSiteLax)
        // The file goes once they're back; the next save writes it again.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aHostOnlyCookieStaysOnItsHost() async throws {
        defer { cleanUp() }
        save([cookie("sid", domain: "www.example.com")])
        let jar = FakeJar()
        await SessionCookies.restore(from: url, into: jar)
        #expect(try #require(jar.cookies.first).domain == "www.example.com")
    }

    @Test func openANewWindowDropsThemUnread() {
        defer { cleanUp() }
        save([cookie("wide", domain: ".youtube.com")])
        let key = NSObject()
        var asked = false
        let began = SessionCookies.prepare(url, resumes: false, for: key) { asked = true; return FakeJar() }
        #expect(!began && !asked && !SessionCookies.isRestoring(key))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theyreBackBeforeThePageAsksForAnything() async {
        defer { cleanUp() }
        save([cookie("wide", domain: ".youtube.com")])
        let key = NSObject()
        let jar = FakeJar()
        jar.delay = .milliseconds(300)
        #expect(SessionCookies.prepare(url, resumes: true, for: key) { jar })
        #expect(SessionCookies.isRestoring(key))
        // What a page's first navigation waits on.
        await SessionCookies.ready(key)
        #expect(jar.cookies.map(\.name) == ["wide"])
        #expect(!SessionCookies.isRestoring(key))
    }

    @Test func aStuckRestoreHoldsPagesOnlySoLong() async {
        defer { cleanUp() }
        save([cookie("wide", domain: ".youtube.com")])
        let key = NSObject()
        let jar = FakeJar()
        jar.delay = .seconds(5)
        SessionCookies.prepare(url, resumes: true, for: key) { jar }
        let start = Date()
        await SessionCookies.ready(key)
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func privateWindowsKeepNone() {
        #expect(SessionCookies.profile(of: WKWebsiteDataStore.nonPersistent()) == nil)
    }

    @Test func theFileIsOwnerOnly() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
        save([cookie("wide", domain: ".youtube.com")])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // Nothing to keep: no file at all.
        save([])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func clearingASiteTakesItsSavedCookies() {
        defer { cleanUp() }
        save([cookie("wide", domain: ".youtube.com"), cookie("pref", domain: "m.youtube.com"), cookie("sid", domain: "example.com"),
              cookie("sid", domain: "github.com")])
        SessionCookies.forget(site: "youtube.com", in: url)
        #expect(Set(SessionCookies.read(url).map(\.domain)) == ["example.com", "github.com"])
        // Every site's but the kept ones.
        SessionCookies.forget(site: nil, keeping: ["github.com"], in: url)
        #expect(SessionCookies.read(url).map(\.domain) == ["github.com"])
        SessionCookies.forget(site: nil, in: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func clearingOnQuitKeepsOnlyKeptSites() {
        let saved = SessionCookies.toSave([cookie("a", domain: ".github.com"), cookie("b", domain: "www.example.com")], keeping: ["github.com"])
        #expect(saved.map(\.domain) == [".github.com"])
    }

    @Test func theSizeIsCapped() throws {
        let many = (0..<1500).map { cookie("c\($0)", domain: "example.com") }
        #expect(SessionCookies.toSave(many).count == SessionCookies.maxCount)
        let value = String(repeating: "x", count: 3000)
        let big = try (0..<300).map { try #require(HTTPCookie(properties: [.name: "b\($0)", .value: value, .domain: "example.com", .path: "/"])) }
        let saved = SessionCookies.toSave(big)
        #expect(saved.count < 300 && !saved.isEmpty)
        #expect(saved.map(\.bytes).reduce(0, +) <= SessionCookies.maxBytes)
    }

    @Test func aValueNeverShowsInADescription() {
        let saved = SessionCookies.Saved(cookie("sid", domain: "example.com"))
        #expect(!String(describing: saved).contains("v-sid"))
        #expect(!String(reflecting: saved).contains("v-sid"))
    }
}

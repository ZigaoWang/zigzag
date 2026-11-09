import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Rules that keep pages and extensions inside their lines: which native helpers an extension may start, which
/// sites it may ask for, and where a link in Reader or a PDF may go.
@MainActor
struct SecurityFixesTests {
    private let id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    @Test func nativeHostNamesFollowChromesRule() {
        #expect(NativeMessagingHost.isValidName("com.1password.1password"))
        #expect(NativeMessagingHost.isValidName("com_example.host_2"))
        #expect(!NativeMessagingHost.isValidName(""))
        #expect(!NativeMessagingHost.isValidName("../../../tmp/evil"))
        #expect(!NativeMessagingHost.isValidName("com/example"))
        #expect(!NativeMessagingHost.isValidName("com..example"))
        #expect(!NativeMessagingHost.isValidName(".com.example"))
        #expect(!NativeMessagingHost.isValidName("com.example."))
        #expect(!NativeMessagingHost.isValidName("Com.Example"))
        #expect(!NativeMessagingHost.isValidName("com.example\n"))
        #expect(!NativeMessagingHost.isValidName("com-example"))
    }

    @Test func nativeHostNeedsTheExactOriginAndAProgram() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SecurityFixesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = folder.appendingPathComponent("helper")
        try Data("#!/bin/sh\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let plain = folder.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: plain)
        let origin = "chrome-extension://\(id)/"

        let host = NativeMessagingHost.host(in: ["path": program.path, "allowed_origins": [origin]], for: id)
        #expect(host?.origin == origin)
        #expect(host?.executable.path == program.standardizedFileURL.path)
        // Not listed, or listed only in part: no helper, as in Chrome.
        #expect(NativeMessagingHost.host(in: ["path": program.path, "allowed_origins": ["chrome-extension://other/"]], for: id) == nil)
        #expect(NativeMessagingHost.host(in: ["path": program.path, "allowed_origins": ["chrome-extension://x\(id)/"]], for: id) == nil)
        #expect(NativeMessagingHost.host(in: ["path": program.path], for: id) == nil)
        // A relative path, a file that isn't a program, a folder, or nothing there.
        #expect(NativeMessagingHost.host(in: ["path": "helper", "allowed_origins": [origin]], for: id) == nil)
        #expect(NativeMessagingHost.host(in: ["path": plain.path, "allowed_origins": [origin]], for: id) == nil)
        #expect(NativeMessagingHost.host(in: ["path": folder.path, "allowed_origins": [origin]], for: id) == nil)
        #expect(NativeMessagingHost.host(in: ["path": folder.appendingPathComponent("gone").path, "allowed_origins": [origin]], for: id) == nil)
    }

    @Test func manifestLookupRefusesBadNames() {
        #expect(NativeMessagingHost.manifest(named: "../../../../../etc/hosts") == nil)
        #expect(NativeMessagingHost.manifest(named: "/tmp/evil") == nil)
    }

    @Test func extensionSiteRequestsStayWithinAccess() throws {
        let pattern = { (s: String) in try WKWebExtension.MatchPattern(string: s) }
        let all = try pattern("<all_urls>")
        let github = try pattern("*://*.github.com/*")
        let api = try pattern("https://api.github.com/*")
        let example = try pattern("*://example.com/*")

        // Only sites I list (github.com): asking for everything, or another site, gets nothing.
        let listed = ExtensionHost.patternsWithinAccess([all, api, example], granted: [github], denied: [])
        #expect(listed == [api])
        // Approved for every site: anything inside that is fine, except a site where extensions are off.
        let everywhere = ExtensionHost.patternsWithinAccess([api, example], granted: [all], denied: [github])
        #expect(everywhere == [example])
        // Nothing granted yet ("when I click it", before a click): nothing.
        #expect(ExtensionHost.patternsWithinAccess([all, api], granted: [], denied: []).isEmpty)
    }

    @Test func readerAndPDFLinksOnlyBrowseTheWeb() throws {
        let url = { (s: String) in try #require(URL(string: s)) }
        #expect(Reader.route(for: try url("https://example.com/a")) == .browse)
        #expect(Reader.route(for: try url("HTTP://example.com")) == .browse)
        #expect(Reader.route(for: try url("file:///etc/passwd")) == .ignore)
        #expect(Reader.route(for: try url("javascript:alert(1)")) == .ignore)
        #expect(Reader.route(for: try url("data:text/html,hi")) == .ignore)
        #expect(Reader.route(for: try url("about:blank")) == .ignore)
        #expect(Reader.route(for: try url("zigzag://settings")) == .ignore)
        #expect(Reader.route(for: try url("mailto:a@example.com")) == .externalApp)
        #expect(Reader.route(for: try url("zoommtg://zoom.us/join")) == .externalApp)
    }
}

/// Site permissions are kept per origin (scheme, host and port), never per host: an answer given to
/// http://localhost:62699 must not let in http://localhost:62700 or https://localhost:62699.
@MainActor
@Suite(.serialized)
struct SiteOriginPermissionTests {
    private func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "zigzag-permissions-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try body(defaults)
    }

    @Test func originLeavesOutOnlyTheSchemesOwnPort() throws {
        #expect(SiteOrigin.of(try url("https://example.com/a?b")) == "https://example.com")
        #expect(SiteOrigin.of(try url("https://example.com:443/")) == "https://example.com")
        #expect(SiteOrigin.of(try url("http://example.com:80/")) == "http://example.com")
        #expect(SiteOrigin.of(try url("https://example.com:80/")) == "https://example.com:80")
        #expect(SiteOrigin.of(try url("http://example.com:443/")) == "http://example.com:443")
        #expect(SiteOrigin.of(try url("http://localhost:62699/")) == "http://localhost:62699")
        #expect(SiteOrigin.of(try url("https://localhost:62699/")) == "https://localhost:62699")
        #expect(SiteOrigin.of(try url("HTTPS://WWW.Example.COM/")) == "https://www.example.com")
        #expect(SiteOrigin.of(try url("http://[::1]:8080/")) == "http://[::1]:8080")
        #expect(SiteOrigin.of(try url("http://[::1]/")) == "http://[::1]")
        #expect(SiteOrigin.make(scheme: "https", host: "::1", port: 0) == "https://[::1]")
        #expect(SiteOrigin.make(scheme: "https", host: "[::1]", port: 8443) == "https://[::1]:8443")
        #expect(SiteOrigin.make(scheme: "HTTP", host: "LOCALHOST", port: 80) == "http://localhost")
        #expect(SiteOrigin.of(try url("blob:https://example.com/0a1b")) == "https://example.com")
        #expect(SiteOrigin.of(try url("webkit-extension://abcdef/popup.html")) == "webkit-extension://abcdef")
    }

    @Test func pagesWithNoHostHaveNoOrigin() throws {
        #expect(SiteOrigin.of(try url("file:///Users/me/page.html")) == nil)
        #expect(SiteOrigin.of(try url("about:blank")) == nil)
        #expect(SiteOrigin.of(try url("data:text/html,hi")) == nil)
        #expect(SiteOrigin.of(nil as URL?) == nil)
        #expect(SiteOrigin.make(scheme: "file", host: "", port: nil) == nil)
        #expect(SiteOrigin.make(scheme: "", host: "example.com", port: nil) == nil)
        #expect(SiteOrigin.make(scheme: "https", host: "a|b", port: nil) == nil)
    }

    @Test func labelsTellPortsAndSchemesApart() {
        #expect(SiteOrigin.label("https://example.com") == "example.com")
        #expect(SiteOrigin.label("https://localhost:8443") == "localhost:8443")
        #expect(SiteOrigin.label("http://localhost:62700") == "http://localhost:62700")
        #expect(SiteOrigin.label("http://example.com") == "http://example.com")
        #expect(SiteOrigin.label("http://localhost:62699") != SiteOrigin.label("http://localhost:62700"))
        #expect(SiteOrigin.label("http://localhost:62699") != SiteOrigin.label("https://localhost:62699"))
        for origin in ["https://example.com", "http://example.com", "https://localhost:8443", "http://[::1]:81"] {
            #expect(SiteOrigin.origin(fromLabel: SiteOrigin.label(origin)) == origin)
        }
    }

    @Test func anAnswerStaysWithItsOrigin() throws {
        try withDefaults { _ in
            let asked = "http://localhost:62699"
            for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
                SitePermissions.remember(true, origin: asked, type: type)
            }
            SitePermissions.setNotifications(true, origin: asked)
            SitePermissions.setPopups(true, origin: asked)
            SitePermissions.allowOpeningApp(origin: asked, scheme: "zoommtg")
            for other in ["http://localhost:62700", "https://localhost:62699", "http://localhost", "https://localhost", "http://127.0.0.1:62699"] {
                for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
                    #expect(SitePermissions.decision(origin: other, type: type) == nil)
                }
                #expect(SitePermissions.notifications(origin: other) == nil)
                #expect(SitePermissions.location(origin: other) == nil)
                #expect(!SitePermissions.popups(origin: other))
                #expect(!SitePermissions.opensApp(origin: other, scheme: "zoommtg"))
                #expect(SitePermissions.choices(origin: other).isEmpty)
            }
            #expect(SitePermissions.decision(origin: asked, type: .microphone) == true)
            #expect(SitePermissions.notifications(origin: asked) == true)
            #expect(SitePermissions.popups(origin: asked))
            #expect(SitePermissions.opensApp(origin: asked, scheme: "zoommtg"))
            #expect(SitePermissions.notificationDecisions == [asked: true])
            #expect(SitePermissions.sites == [asked])
            // A shorter port that starts the same is another site too.
            #expect(SitePermissions.choices(origin: "http://localhost:6269").isEmpty)
            SitePermissions.forgetEverything(origin: "http://localhost:6269")
            #expect(SitePermissions.sites == [asked])
            SitePermissions.forgetEverything(origin: asked)
            #expect(SitePermissions.sites.isEmpty)
        }
    }

    @Test func oldHostOnlyAllowsAreDroppedAndDenialsKeptForHttps() throws {
        try withDefaults { defaults in
            defaults.set(["localhost|microphone": true, "localhost|camera": false, "example.com|location": true,
                          "example.com|notifications": false, "zoom.us|app:zoommtg": true, "x.com|popups": true,
                          "https://kept.com|camera": true, "https://example.com|notifications": true], forKey: "SitePermissions")
            defaults.set(true, forKey: "UnrelatedSetting")
            SitePermissions.migrateHostOnlyAnswers()
            let now = defaults.dictionary(forKey: "SitePermissions") as? [String: Bool]
            // An answer already kept for the origin stays as it was.
            #expect(now == ["https://localhost|camera": false, "https://kept.com|camera": true, "https://example.com|notifications": true])
            #expect(SitePermissions.decision(origin: "http://localhost", type: .microphone) == nil)
            #expect(SitePermissions.decision(origin: "https://localhost", type: .microphone) == nil)
            #expect(SitePermissions.decision(origin: "http://localhost", type: .camera) == nil)
            #expect(SitePermissions.location(origin: "https://example.com") == nil)
            #expect(!SitePermissions.popups(origin: "https://x.com"))
            #expect(!SitePermissions.opensApp(origin: "https://zoom.us", scheme: "zoommtg"))
            #expect(defaults.bool(forKey: "UnrelatedSetting"))
            // Once is enough: again, nothing changes.
            SitePermissions.migrateHostOnlyAnswers()
            #expect(defaults.dictionary(forKey: "SitePermissions") as? [String: Bool] == now)
        }
    }

    @Test func migratingNothingWritesNothing() throws {
        try withDefaults { defaults in
            SitePermissions.migrateHostOnlyAnswers()
            #expect(defaults.object(forKey: "SitePermissions") == nil)
        }
    }
}

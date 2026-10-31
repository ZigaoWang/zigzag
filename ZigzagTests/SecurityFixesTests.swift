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

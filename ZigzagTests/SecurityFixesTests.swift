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

/// A frame from another site asks as itself on that page only: what it was told on one site never lets it in on
/// another, nor on its own site.
@Suite(.serialized)
@MainActor
struct EmbeddedPermissionTests {
    private func withDefaults(_ body: () throws -> Void) throws {
        let suite = "zigzag-embedded-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try body()
    }

    @Test func aFrameOnItsOwnSiteAsksAsThePage() {
        #expect(SitePermissions.answerKey(frame: "https://meet.example", page: "https://meet.example") == "https://meet.example")
        #expect(SitePermissions.answerKey(frame: "https://meet.example", page: "https://news.example") == "https://news.example|embed:https://meet.example")
        #expect(SitePermissions.answerKey(frame: "https://meet.example", page: nil) == nil)
        #expect(SitePermissions.answerKey(frame: nil, page: "https://news.example") == nil)
    }

    @Test func anEmbeddedAnswerStaysOnItsPage() throws {
        try withDefaults {
            let frame = "https://meet.example", news = "https://news.example"
            // Allowed on its own site, it still asks when another site frames it.
            SitePermissions.remember(true, origin: frame, type: .camera)
            let embedded = try #require(SitePermissions.answerKey(frame: frame, page: news))
            #expect(SitePermissions.decision(origin: embedded, type: .camera) == nil)
            // Allowed framed by one site, it asks framed by another, and on its own site.
            SitePermissions.remember(true, origin: embedded, type: .microphone)
            let elsewhere = try #require(SitePermissions.answerKey(frame: frame, page: "https://evil.example"))
            #expect(SitePermissions.decision(origin: elsewhere, type: .microphone) == nil)
            #expect(SitePermissions.decision(origin: frame, type: .microphone) == nil)
            #expect(SitePermissions.decision(origin: news, type: .microphone) == nil)
            // Kept under the page: it's the page's row, and forgetting the page forgets it.
            #expect(SitePermissions.sites == [frame, news])
            #expect(SitePermissions.mediaDecisions(origin: news) == [true])
            #expect(SitePermissions.mediaDecisions(origin: frame) == [true])
            SitePermissions.forget(origin: news)
            #expect(SitePermissions.decision(origin: embedded, type: .microphone) == nil)
            #expect(SitePermissions.decision(origin: frame, type: .camera) == true)
            SitePermissions.remember(false, origin: embedded, type: .camera)
            SitePermissions.forgetEverything(origin: news)
            #expect(SitePermissions.sites == [frame])
        }
    }

    @Test func embeddedLocationIsForgottenWithThePage() throws {
        try withDefaults {
            let embedded = try #require(SitePermissions.answerKey(frame: "https://maps.example", page: "https://shop.example"))
            SitePermissions.defaults.set(["\(embedded)|location": true, "https://maps.example|location": false], forKey: "SitePermissions")
            #expect(SitePermissions.locationDecisions(origin: "https://shop.example") == [true])
            #expect(SitePermissions.location(origin: "https://shop.example") == nil)
            SitePermissions.forgetLocation(origin: "https://shop.example")
            #expect(SitePermissions.locationDecisions(origin: "https://shop.example").isEmpty)
            #expect(SitePermissions.location(origin: "https://maps.example") == false)
        }
    }

    @Test func theQuestionNamesTheFrameAndThePage() {
        #expect(SitePermissions.askerName(frame: "https://meet.example", page: "https://meet.example") == "meet.example")
        let both = SitePermissions.askerName(frame: "https://meet.example", page: "http://localhost:3000")
        #expect(both.contains("meet.example") && both.contains("http://localhost:3000"))
        #expect(SitePermissions.askerName(frame: "https://meet.example", page: nil).contains("meet.example"))
    }
}

/// Pop-up notices, toasts' actions, notification icons and pop-up headers: what a page can't use against you.
@MainActor
struct PageNoticeTests {
    @Test func aToastsActionWaitsAHalfSecond() {
        let shown = Date()
        #expect(!Toast.acceptsAction(shownAt: shown, now: shown))
        #expect(!Toast.acceptsAction(shownAt: shown, now: shown.addingTimeInterval(0.4)))
        #expect(Toast.acceptsAction(shownAt: shown, now: shown.addingTimeInterval(0.6)))
    }

    @Test func aBlockedPopupIsSaidOnceInAWhile() {
        let key = "test-\(UUID().uuidString)|https://example.com", now = Date()
        #expect(PopupNotice.shouldNotice(key, now: now))
        #expect(!PopupNotice.shouldNotice(key, now: now.addingTimeInterval(1)))
        #expect(!PopupNotice.shouldNotice(key, now: now.addingTimeInterval(PopupNotice.noticeInterval - 1)))
        #expect(PopupNotice.shouldNotice("test-\(UUID().uuidString)|https://other.example", now: now.addingTimeInterval(1)))
        #expect(PopupNotice.shouldNotice(key, now: now.addingTimeInterval(PopupNotice.noticeInterval + 1)))
    }

    @Test func onlyWebPopupsAreOffered() throws {
        let page = try #require(URL(string: "https://pay.example/checkout"))
        #expect(PopupNotice.offered(page) == (true, page))
        #expect(PopupNotice.offered(nil) == (true, nil))
        #expect(PopupNotice.offered(URL(string: "about:blank")) == (true, nil))
        #expect(PopupNotice.offered(URL(string: "javascript:alert(1)")) == (false, nil))
        #expect(PopupNotice.offered(URL(string: "data:text/html,hi")) == (false, nil))
    }

    @Test func iconsComeOnlyFromPublicAddresses() {
        for address in ["127.0.0.1", "127.1.2.3", "10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
                        "0.0.0.0", "100.64.0.1", "224.0.0.1", "255.255.255.255", "::1", "::", "[::1]", "fe80::1", "fc00::1",
                        "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:192.168.0.1", "64:ff9b::a00:1", "2002:c0a8:101::1",
                        "not an address", ""] {
            #expect(!IconAddress.isPublic(address), "\(address)")
        }
        for address in ["8.8.8.8", "93.184.216.34", "172.32.0.1", "192.169.0.1", "2606:4700::1111", "::ffff:8.8.8.8"] {
            #expect(IconAddress.isPublic(address), "\(address)")
        }
        for name in ["localhost", "LOCALHOST.", "app.localhost", "printer.local", "router.home.arpa", "db.internal", ""] {
            #expect(!IconAddress.isPublicName(name), "\(name)")
        }
        #expect(IconAddress.isPublicName("cdn.example.com"))
    }

    @Test func iconsAreFetchedOnlyOverTheWeb() async throws {
        for text in ["http://127.0.0.1/icon.png", "https://[::1]/icon.png", "http://localhost:8080/icon.png", "http://192.168.1.1/x.png",
                     "file:///etc/hosts", "ftp://8.8.8.8/x.png", "http://169.254.169.254/latest"] {
            let url = try #require(URL(string: text))
            #expect(await !IconAddress.mayFetch(url), "\(text)")
        }
        #expect(await IconAddress.mayFetch(try #require(URL(string: "https://8.8.8.8/icon.png"))))
    }

    @Test func popupHeaderNamesASiteOnlyWhenThereIsOne() {
        #expect(PopupHeaderView.site(of: URL(string: "https://accounts.example.com/signin")) == "accounts.example.com")
        #expect(PopupHeaderView.site(of: URL(string: "https://accounts.example.com:81/")) == "accounts.example.com:81")
        #expect(PopupHeaderView.site(of: URL(string: "blob:https://pay.example/0a1b-2c3d")) == "pay.example")
        #expect(PopupHeaderView.site(of: URL(string: "blob:http://localhost:3000/0a1b")) == "localhost:3000")
        #expect(PopupHeaderView.site(of: URL(string: "data:text/html,hi")) == nil)
        #expect(PopupHeaderView.site(of: URL(string: "about:blank")) == nil)
        #expect(PopupHeaderView.site(of: URL(string: "blob:null/0a1b")) == nil)
        #expect(PopupHeaderView.site(of: nil) == nil)
    }
}

/// Passwords and sign-ins stay where they belong: in the file you export, the cookies you bring over, the menu
/// that fills a page, and the sheet a site's sign-in asks with.
@MainActor
struct PasswordSafetyTests {
    @Test func exportedFieldsNeverRunAsFormulas() {
        #expect(PasswordExport.field("=HYPERLINK(\"https://evil.example\")") == "\"'=HYPERLINK(\"\"https://evil.example\"\")\"")
        for start in ["+1", "-2", "@SUM(A1)", "\tx"] { #expect(PasswordExport.field(start) == "'" + start) }
        #expect(PasswordExport.field("\rx") == "\"'\rx\"")
        #expect(PasswordExport.field("\r\nx") == "\"'\r\nx\"")
        #expect(PasswordExport.field("sam@example.com") == "sam@example.com")
        #expect(PasswordExport.field("a,b") == "\"a,b\"")
        // The password stays exactly as it is, or the file wouldn't sign you in.
        #expect(PasswordExport.field("=secret", neutralized: false) == "=secret")
    }

    @Test func importCopiesAreYoursAloneAndLeftoversGo() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent("PasswordSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let old = try ImportScratch.makeFolder("zigzag-safari-", in: parent)
        #expect((try fm.attributesOfItem(atPath: old.path))[.posixPermissions] as? Int == 0o700)
        try fm.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        let fresh = try ImportScratch.makeFolder("zigzag-import-", in: parent)
        let other = parent.appendingPathComponent("someone-else", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: other.path)

        ImportScratch.removeLeftovers(in: parent)
        #expect(!fm.fileExists(atPath: old.path))
        // One made just now may be another Zigzag's import in progress; folders that aren't Zigzag's stay.
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: other.path))
    }

    // MARK: Pages

    private final class Loading: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    /// A made-up page on https://example.com, in a window that's never shown.
    private func page(_ html: String, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) async -> (WKWebView, NSWindow, Loading) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        window.contentView = webView
        let loading = Loading()
        webView.navigationDelegate = loading
        await withCheckedContinuation { done in
            loading.done = done
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
        return (webView, window, loading)
    }

    private func value(_ id: String, in webView: WKWebView) async -> String? {
        try? await webView.evaluateJavaScript("document.getElementById('\(id)').value") as? String
    }

    private func fillMyCard(_ webView: WKWebView, focusing id: String) async throws {
        _ = try await webView.evaluateJavaScript("document.getElementById('\(id)').focus()")
        let values: [String: String] = ["given-name": "Ada", "email": "ada@example.com", "tel": "555 0100"]
        _ = try await webView.callAsyncJavaScript(Autofill.formFiller, arguments: ["values": values, "expectedOrigin": "https://example.com"],
                                                  in: nil, contentWorld: .defaultClient)
    }

    @Test func myCardFillsOnlyWhatsOnScreen() async throws {
        let (webView, _, _) = await page("""
        <form><input id="name" name="first_name"><input id="email" name="email"><div style="height: 1000px"></div><input id="far" name="phone"></form>
        """)
        try await fillMyCard(webView, focusing: "name")
        #expect(await value("name", in: webView) == "Ada")
        #expect(await value("email", in: webView) == "ada@example.com")
        // Below the screen: you'd never see it filled.
        #expect(await value("far", in: webView) == "")
    }

    @Test func myCardFillsOnlyYourPartOfTheForm() async throws {
        let (webView, _, _) = await page("""
        <form><input id="name" autocomplete="shipping given-name"><input id="email" autocomplete="shipping email">
        <input id="billing" autocomplete="billing email"></form>
        """)
        try await fillMyCard(webView, focusing: "name")
        #expect(await value("email", in: webView) == "ada@example.com")
        #expect(await value("billing", in: webView) == "")
    }

    /// What the password watcher tells Zigzag, by kind.
    private final class Heard: NSObject, WKScriptMessageHandler {
        var kinds: [String] = []
        var waiting: (kind: String, done: CheckedContinuation<Void, Never>)?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let kind = (message.body as? [String: Any])?["kind"] as? String else { return }
            kinds.append(kind)
            if let waiting, waiting.kind == kind { self.waiting = nil; waiting.done.resume() }
        }
        func wait(for kind: String) async {
            if kinds.contains(kind) { return }
            await withCheckedContinuation { waiting = (kind, $0) }
        }
    }

    @Test func aPageCantOfferItsOwnPasswordForSaving() async throws {
        let heard = Heard()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PasswordCapture.script)
        configuration.userContentController.add(heard, contentWorld: .defaultClient, name: PasswordCapture.messageName)
        let (webView, _, _) = await page("""
        <form action="#"><input id="user" name="username" autocomplete="username"><input id="pass" type="password"><button>Sign in</button></form>
        """, configuration: configuration)
        await heard.wait(for: "page")
        // The page fills in values of its own, says they were typed, and sends the form, all without you.
        _ = try await webView.evaluateJavaScript("""
        user.value = 'sam@example.com'; pass.value = 'page-chosen';
        pass.dispatchEvent(new InputEvent('input', { bubbles: true }));
        document.querySelector('button').click();
        document.querySelector('form').requestSubmit();
        """)
        // Anything the watcher posted arrives before this.
        _ = try await webView.callAsyncJavaScript("window.webkit.messageHandlers.zigzagPassword.postMessage({ kind: 'done' })", arguments: [:],
                                                  in: nil, contentWorld: .defaultClient)
        await heard.wait(for: "done")
        #expect(!heard.kinds.contains("login"))
        #expect(!heard.kinds.contains("change"))
    }

    // MARK: Saved logins

    private func login(_ site: String, _ username: String) -> Credential {
        Credential(id: UUID(), origin: Origin(URL(string: site))!, username: username, title: "", notes: "", otpAuth: "",
                   created: Date(), modified: Date(), lastUsed: nil)
    }

    @Test func signInSheetFillsInOnlyThisAddresssLogin() throws {
        let here = try #require(Origin(URL(string: "https://router.example.com")))
        let exact = login("https://router.example.com", "admin")
        let elsewhere = login("https://mail.example.com", "sam")
        #expect(AuthenticationPrompt.prefill([exact, elsewhere], for: here)?.id == exact.id)
        // Saved for another part of the site only: nothing filled in; it waits behind Saved Passwords.
        #expect(AuthenticationPrompt.prefill([elsewhere], for: here) == nil)
        // Two for this address: you choose.
        #expect(AuthenticationPrompt.prefill([exact, login("https://router.example.com", "guest")], for: here) == nil)
    }

    private func logins(_ items: [AutofillMenu.Item]) -> [String] {
        items.map { item in
            switch item {
            case .login(let login): login.username
            case .elsewhere(let logins): "elsewhere: " + logins.map(\.username).joined(separator: ",")
            default: "other"
            }
        }
    }

    @Test func otherPartsOfTheSiteWaitBehindTheirOwnRow() throws {
        let here = try #require(Origin(URL(string: "https://www.example.com")))
        let mine = login("https://www.example.com", "sam"), old = login("http://www.example.com", "old")
        let mail = login("https://mail.example.com", "mail")
        #expect(logins(Autofill.menuItems([mail, mine, old], on: here)) == ["sam", "old", "elsewhere: mail"])
        #expect(logins(Autofill.menuItems([mail], on: here)) == ["elsewhere: mail"])
        #expect(logins(Autofill.menuItems([mine], on: here)) == ["sam"])
    }

    @Test func theMenuTakesNoClickForHalfASecond() async throws {
        let menu = AutofillMenu(items: [.login(login("https://www.example.com", "sam"))], origin: try #require(Origin(URL(string: "https://www.example.com"))))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.addSubview(menu)
        menu.frame = NSRect(x: 0, y: 0, width: 300, height: menu.contentHeight)
        menu.needsLayout = true
        menu.layoutSubtreeIfNeeded()
        // The middle of the first row, in its superview's terms, as hit-testing takes it.
        let onRow = menu.convert(NSPoint(x: 150, y: 28), to: host)
        #expect(menu.hitTest(onRow) === menu)
        try await Task.sleep(for: .milliseconds(600))
        let hit = try #require(menu.hitTest(onRow))
        #expect(hit !== menu)
        #expect(hit is InteractiveView)
    }

    @Test func aPageMovingTheCursorDoesntOpenTheMenu() async throws {
        let heard = Heard()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(Autofill.script)
        configuration.userContentController.add(heard, contentWorld: .defaultClient, name: Autofill.messageName)
        let (webView, _, _) = await page("""
        <form><input id="user" name="username" autocomplete="username" autofocus><input id="pass" type="password"></form>
        <script>setTimeout(() => document.getElementById('pass').focus(), 0)</script>
        """, configuration: configuration)
        #expect(try await webView.evaluateJavaScript("!!window.__zigzagAutofillWatcher", in: nil, contentWorld: .defaultClient) as? Bool == true)
        _ = try await webView.evaluateJavaScript("""
        document.getElementById('user').focus();
        document.getElementById('pass').dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
        document.getElementById('pass').focus();
        """)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await webView.callAsyncJavaScript("window.webkit.messageHandlers.zigzagAutofill.postMessage({ kind: 'done' })", arguments: [:],
                                                  in: nil, contentWorld: .defaultClient)
        await heard.wait(for: "done")
        #expect(!heard.kinds.contains("focus"))
    }
}

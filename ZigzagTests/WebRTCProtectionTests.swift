import Foundation
import Testing
import WebKit
@testable import Zigzag

/// WebRTC IP protection (#229): which pages get WebRTC, the Site Controls row, private window choices, and WebKit's switch.
@MainActor
@Suite(.serialized)
struct WebRTCProtectionTests {
    private let site = "https://meet.example.com"

    private func withDefaults(_ body: () async throws -> Void) async throws {
        let suite = "zigzag-webrtc-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        SitePermissions.forgetAsked()
        defer {
            SitePermissions.defaults = before
            SitePermissions.forgetAsked()
            defaults.removeScratchSuite(suite)
        }
        try await body()
    }

    @Test func theDecision() {
        // Off (default): every site has it.
        #expect(WebRTCProtection.allows(protectionOn: false, kept: nil, here: nil))
        // On: none have it unless allowed.
        #expect(!WebRTCProtection.allows(protectionOn: true, kept: nil, here: nil))
        #expect(WebRTCProtection.allows(protectionOn: true, kept: true, here: nil))
        // A blocked site stays off with the setting off.
        #expect(!WebRTCProtection.allows(protectionOn: false, kept: false, here: nil))
        // A private tab's choice comes first.
        #expect(WebRTCProtection.allows(protectionOn: true, kept: false, here: true))
        #expect(!WebRTCProtection.allows(protectionOn: false, kept: true, here: false))
    }

    @Test func offUnlessTurnedOn() async throws {
        try await withDefaults {
            #expect(!WebRTCProtection.isOn)
            #expect(WebRTCProtection.allows(URL(string: site), in: nil))
            #expect(SitePermissions.shown(origin: site, isPrivate: false).isEmpty)
        }
    }

    @Test func onBlocksAllButSitesAllowed() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            #expect(!WebRTCProtection.allows(URL(string: site + "/abc"), in: nil))
            // Pages without a site follow the setting.
            #expect(!WebRTCProtection.allows(URL(string: "about:blank"), in: nil))
            WebRTCProtection.choose(true, origin: site, in: nil)
            #expect(WebRTCProtection.allows(URL(string: site + "/abc"), in: nil))
            // Another origin on the host is a separate site.
            #expect(!WebRTCProtection.allows(URL(string: "http://meet.example.com"), in: nil))
            #expect(SitePermissions.webRTC(origin: site) == true)
        }
    }

    @Test func itsRowInSiteControls() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            #expect(SitePermission.webRTC.choices == [.allow, .block])
            #expect(SitePermission.camera.choices == PermissionChoice.allCases)
            // On: every site shows the row, Block until allowed.
            WebRTCProtection.isOn = true
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.webRTC])
            #expect(SitePermissions.shown(origin: site, isPrivate: true) == [.webRTC])
            #expect(SitePermissions.choice(.webRTC, origin: site) == .block)
            SitePermissions.setChoice(.allow, for: .webRTC, origin: site)
            #expect(SitePermissions.choice(.webRTC, origin: site) == .allow)
            // Off: only sites with a kept choice show the row.
            WebRTCProtection.isOn = false
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.webRTC])
            #expect(SitePermissions.shown(origin: "https://other.example.com", isPrivate: false).isEmpty)
            // Reset Permissions returns it to the setting.
            SitePermissions.reset(origin: site)
            #expect(SitePermissions.webRTC(origin: site) == nil)
            #expect(SitePermissions.shown(origin: site, isPrivate: false).isEmpty)
        }
    }

    @Test func theSettingAloneIsNotTheSitesChoice() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            // On: every site has the row so calls can be allowed in advance, but the setting's Block isn't a site answer: not counted, nothing to reset.
            WebRTCProtection.isOn = true
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.webRTC])
            #expect(!SitePermissions.isOwn(.webRTC, origin: site))
            // A private tab's choice counts as the site's there.
            #expect(SitePermissions.isOwn(.webRTC, origin: site, here: true))
            // Asked (a call tried to start) or chosen: the site's own.
            SitePermissions.noteAsked(.webRTC, origin: site, isPrivate: false)
            #expect(SitePermissions.isOwn(.webRTC, origin: site))
            SitePermissions.forgetAsked()
            SitePermissions.setChoice(.allow, for: .webRTC, origin: site)
            #expect(SitePermissions.isOwn(.webRTC, origin: site))
            // Reset returns it to the setting.
            SitePermissions.reset(origin: site)
            #expect(!SitePermissions.isOwn(.webRTC, origin: site))
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.webRTC])
        }
    }

    @Test func aPrivateWindowKeepsNothing() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            let tab = Tab(url: URL(string: site), title: "Meet", spaceID: UUID())
            tab.privateStore = .nonPersistent()
            WebRTCProtection.choose(true, origin: site, in: tab)
            #expect(WebRTCProtection.allows(URL(string: site), in: tab))
            #expect(WebRTCProtection.choice(origin: site, in: tab) == .allow)
            // Nothing kept for the site or other tabs.
            #expect(SitePermissions.webRTC(origin: site) == nil)
            #expect(!WebRTCProtection.allows(URL(string: site), in: Tab(url: URL(string: site), spaceID: UUID())))
            // Follows choices kept for other sites.
            SitePermissions.setChoice(.allow, for: .webRTC, origin: "https://call.example.com")
            #expect(WebRTCProtection.allows(URL(string: "https://call.example.com"), in: tab))
        }
    }

    /// A private tab's popup keeps the tab's choices after it closes (`PopupWindowController.webRTCChoices`), as a copy.
    @Test func aPopUpKeepsItsPrivateOpenersChoice() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            var tab: Tab? = Tab(url: URL(string: site), title: "Meet", spaceID: UUID())
            tab?.privateStore = .nonPersistent()
            WebRTCProtection.choose(true, origin: site, in: tab)
            let kept = tab?.webRTCHere
            tab = nil
            #expect(WebRTCProtection.allows(URL(string: site + "/call"), here: kept))
            #expect(!WebRTCProtection.allows(URL(string: site + "/call"), here: nil))
            let page = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            WebRTCProtection.apply(to: page, for: URL(string: site), here: kept)
            #expect(page.configuration.preferences.value(forKey: "peerConnectionEnabled") as? Bool == true)
        }
    }

    @Test func aNewWindowGetsItsOwnSwitch() throws {
        guard WebRTCProtection.isAvailable else { return }
        let configuration = WKWebViewConfiguration()
        let opener = WKWebView(frame: .zero, configuration: configuration)
        WebKitSetup.separatePreferences(of: configuration)
        let popup = WKWebView(frame: .zero, configuration: configuration)
        #expect(opener.configuration.preferences !== popup.configuration.preferences)
        popup.configuration.preferences.setValue(false, forKey: "peerConnectionEnabled")
        #expect(opener.configuration.preferences.value(forKey: "peerConnectionEnabled") as? Bool == true)
    }

    @Test func pagesHaveNoPeerConnectionWhenBlocked() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            let configuration = WKWebViewConfiguration()
            WebRTCProtection.attach(to: configuration)
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
            WebRTCProtection.apply(to: webView, for: URL(string: site), in: nil)
            let blocked = try await Self.peerConnectionType(in: webView)
            #expect(blocked == "undefined")
            WebRTCProtection.choose(true, origin: site, in: nil)
            WebRTCProtection.apply(to: webView, for: URL(string: site), in: nil)
            let allowed = try await Self.peerConnectionType(in: webView)
            #expect(allowed == "function")
        }
    }

    // MARK: A page that tries on its own (#276)

    @Test func whenTheNoticeShows() {
        // Blocked, unchosen, main frame, first time: notice.
        #expect(WebRTCProtection.notices(allowed: false, chosen: nil, isMainFrame: true, noticedHere: false, askedHere: false, putAway: false))
        // Allowed: no notice.
        #expect(!WebRTCProtection.notices(allowed: true, chosen: nil, isMainFrame: true, noticedHere: false, askedHere: false, putAway: false))
        #expect(!WebRTCProtection.notices(allowed: true, chosen: true, isMainFrame: true, noticedHere: false, askedHere: false, putAway: false))
        // Blocked by choice: silent.
        #expect(!WebRTCProtection.notices(allowed: false, chosen: false, isMainFrame: true, noticedHere: false, askedHere: false, putAway: false))
        // A subframe (an ad's): silent.
        #expect(!WebRTCProtection.notices(allowed: false, chosen: nil, isMainFrame: false, noticedHere: false, askedHere: false, putAway: false))
        // Once per page, and not after asking.
        #expect(!WebRTCProtection.notices(allowed: false, chosen: nil, isMainFrame: true, noticedHere: true, askedHere: false, putAway: false))
        #expect(!WebRTCProtection.notices(allowed: false, chosen: nil, isMainFrame: true, noticedHere: false, askedHere: true, putAway: false))
        // Dismissed this session: not again.
        #expect(!WebRTCProtection.notices(allowed: false, chosen: nil, isMainFrame: true, noticedHere: false, askedHere: false, putAway: true))
    }

    @Test func theNoticeShowsOnceAPage() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            let origin = "https://once-\(UUID().uuidString.lowercased()).example.com"
            let tab = Tab(url: URL(string: origin + "/call"), title: "Call", spaceID: UUID())
            // Off: every site has WebRTC, no notice.
            #expect(!WebRTCProtection.notice(in: tab, isMainFrame: true))
            WebRTCProtection.isOn = true
            #expect(!WebRTCProtection.notice(in: tab, isMainFrame: false))
            #expect(WebRTCProtection.notice(in: tab, isMainFrame: true))
            #expect(!WebRTCProtection.notice(in: tab, isMainFrame: true))
            // The next load shows it again.
            tab.permissionAnswers.forget()
            #expect(WebRTCProtection.notice(in: tab, isMainFrame: true))
        }
    }

    @Test func allowFromTheNoticeKeepsItForTheSite() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            let origin = "https://allow-\(UUID().uuidString.lowercased()).example.com"
            let tab = Tab(url: URL(string: origin), title: "Call", spaceID: UUID())
            #expect(WebRTCProtection.notice(in: tab, isMainFrame: true))
            // Allow for This Site: kept for the site, shown in Site Controls.
            WebRTCProtection.choose(true, origin: origin, in: tab)
            #expect(SitePermissions.webRTC(origin: origin) == true)
            #expect(SitePermissions.choice(.webRTC, origin: origin) == .allow)
            tab.permissionAnswers.forget()
            #expect(!WebRTCProtection.notice(in: tab, isMainFrame: true))
            // In a private window: for that tab only.
            let other = "https://private-\(UUID().uuidString.lowercased()).example.com"
            let privateTab = Tab(url: URL(string: other), title: "Call", spaceID: UUID())
            privateTab.privateStore = .nonPersistent()
            #expect(WebRTCProtection.notice(in: privateTab, isMainFrame: true))
            WebRTCProtection.choose(true, origin: other, in: privateTab)
            #expect(SitePermissions.webRTC(origin: other) == nil)
            #expect(privateTab.webRTCHere[other] == true)
            privateTab.permissionAnswers.forget()
            #expect(!WebRTCProtection.notice(in: privateTab, isMainFrame: true))
        }
    }

    /// Loads a fresh page and reads `typeof RTCPeerConnection`.
    private static func peerConnectionType(in webView: WKWebView) async throws -> String? {
        let token = UUID().uuidString
        webView.loadHTMLString("<p id='\(token)'>hi</p>", baseURL: URL(string: "https://meet.example.com/"))
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? await webView.evaluateJavaScript("!!document.getElementById('\(token)')")) as? Bool == true { break }
        }
        return try await webView.evaluateJavaScript("typeof RTCPeerConnection") as? String
    }
}

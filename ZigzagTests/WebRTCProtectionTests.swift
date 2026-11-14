import Foundation
import Testing
import WebKit
@testable import Zigzag

/// WebRTC and your IP address (#229): which pages get it, the Site Controls row, a private window's choice, and
/// WebKit's switch itself.
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
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    @Test func theDecision() {
        // Off, as it starts: every site has it.
        #expect(WebRTCProtection.allows(protectionOn: false, kept: nil, here: nil))
        // On: none has it, unless allowed.
        #expect(!WebRTCProtection.allows(protectionOn: true, kept: nil, here: nil))
        #expect(WebRTCProtection.allows(protectionOn: true, kept: true, here: nil))
        // A site blocked keeps it off with the setting off.
        #expect(!WebRTCProtection.allows(protectionOn: false, kept: false, here: nil))
        // A private tab's own choice comes first.
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
            // A page with no site follows the setting.
            #expect(!WebRTCProtection.allows(URL(string: "about:blank"), in: nil))
            WebRTCProtection.choose(true, origin: site, in: nil)
            #expect(WebRTCProtection.allows(URL(string: site + "/abc"), in: nil))
            // Another origin on the host is its own site.
            #expect(!WebRTCProtection.allows(URL(string: "http://meet.example.com"), in: nil))
            #expect(SitePermissions.webRTC(origin: site) == true)
        }
    }

    @Test func itsRowInSiteControls() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            #expect(SitePermission.webRTC.choices == [.allow, .block])
            #expect(SitePermission.cameraAndMicrophone.choices == PermissionChoice.allCases)
            // While it's on, every site has the row, Block until allowed.
            WebRTCProtection.isOn = true
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.webRTC])
            #expect(SitePermissions.shown(origin: site, isPrivate: true) == [.webRTC])
            #expect(SitePermissions.choice(.webRTC, origin: site) == .block)
            SitePermissions.setChoice(.allow, for: .webRTC, origin: site)
            #expect(SitePermissions.choice(.webRTC, origin: site) == .allow)
            // Off, the row stays for a site with a choice kept, and none for the rest.
            WebRTCProtection.isOn = false
            #expect(SitePermissions.shown(origin: site, isPrivate: false) == [.webRTC])
            #expect(SitePermissions.shown(origin: "https://other.example.com", isPrivate: false).isEmpty)
            // Reset Permissions puts it back to the setting.
            SitePermissions.reset(origin: site)
            #expect(SitePermissions.webRTC(origin: site) == nil)
            #expect(SitePermissions.shown(origin: site, isPrivate: false).isEmpty)
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
            // Nothing kept for the site, nor for any other tab.
            #expect(SitePermissions.webRTC(origin: site) == nil)
            #expect(!WebRTCProtection.allows(URL(string: site), in: Tab(url: URL(string: site), spaceID: UUID())))
            // It follows a choice kept elsewhere.
            SitePermissions.setChoice(.allow, for: .webRTC, origin: "https://call.example.com")
            #expect(WebRTCProtection.allows(URL(string: "https://call.example.com"), in: tab))
        }
    }

    @Test func aNewWindowGetsItsOwnSwitch() throws {
        guard WebRTCProtection.isAvailable else { return }
        let configuration = WKWebViewConfiguration()
        let opener = WKWebView(frame: .zero, configuration: configuration)
        WebRTCProtection.isolate(configuration)
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

    /// Loads a fresh page and reads `typeof RTCPeerConnection` in it.
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

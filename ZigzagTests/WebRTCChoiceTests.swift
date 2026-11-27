import Foundation
import Testing
import WebKit
@testable import Zigzag

/// WebRTC as an ordinary permission (#545): Allow, Don't Allow, and Ask like every other kind. Before, its row offered
/// only Allow and Block, and once a choice was kept the site was never asked again for its whole life.
@MainActor
@Suite(.serialized)
struct WebRTCChoiceTests {
    private let site = "https://meet.example.com"

    private func withDefaults(_ body: () async throws -> Void) async throws {
        let suite = "zigzag-webrtc-choice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let before = SitePermissions.defaults
        SitePermissions.defaults = defaults
        defer {
            SitePermissions.defaults = before
            defaults.removePersistentDomain(forName: suite)
        }
        try await body()
    }

    @Test func itsRowOffersAskLikeEveryOtherPermission() {
        #expect(SitePermission.webRTC.choices == PermissionChoice.allCases)
        #expect(SitePermission.webRTC.choices.contains(.ask))
        // The other kinds are unchanged.
        #expect(SitePermission.camera.choices == PermissionChoice.allCases)
    }

    @Test func aFreshSiteReadsAsk() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            #expect(WebRTCProtection.choice(origin: site, in: nil) == .ask)
        }
    }

    @Test func aKeptChoiceReadsBack() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            WebRTCProtection.choose(false, origin: site, in: nil)
            #expect(WebRTCProtection.choice(origin: site, in: nil) == .block)
            WebRTCProtection.choose(true, origin: site, in: nil)
            #expect(WebRTCProtection.choice(origin: site, in: nil) == .allow)
        }
    }

    @Test func backToAskForgetsTheKeptChoice() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = true
            WebRTCProtection.choose(true, origin: site, in: nil)
            #expect(SitePermissions.webRTC(origin: site) == true)
            // Ask forgets, so the next attempt asks again rather than being refused or allowed for good.
            WebRTCProtection.forget(origin: site)
            #expect(SitePermissions.webRTC(origin: site) == nil)
            #expect(WebRTCProtection.choice(origin: site, in: nil) == .ask)
        }
    }

    @Test func protectionOffReadsAllow() async throws {
        guard WebRTCProtection.isAvailable else { return }
        try await withDefaults {
            WebRTCProtection.isOn = false
            #expect(SitePermissions.webRTC(origin: site) == nil)
            #expect(WebRTCProtection.choice(origin: site, in: nil) == .allow)
        }
    }
}

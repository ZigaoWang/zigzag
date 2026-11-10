import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Muting a tab changes only its sound, never its camera, microphone or screen capture, and what the tab says is
/// what WebKit says.
struct TabMuteTests {
    // WebKit's _WKMediaMutedState: sound, capture devices, screen capture.
    private let sound = 1, devices = 2, screen = 4

    @Test func mutingKeepsTheCaptureFlags() {
        #expect(WKWebView.mutedFlags(0, audioMuted: true) == sound)
        #expect(WKWebView.mutedFlags(devices, audioMuted: true) == sound | devices)
        #expect(WKWebView.mutedFlags(devices | screen, audioMuted: true) == sound | devices | screen)
    }

    @Test func unmutingLeavesAMutedMicrophoneMuted() {
        #expect(WKWebView.mutedFlags(sound | devices, audioMuted: false) == devices)
        #expect(WKWebView.mutedFlags(sound, audioMuted: false) == 0)
        #expect(WKWebView.mutedFlags(screen, audioMuted: false) == screen)
    }

    @Test func onlyTheSoundFlagCountsAsMuted() {
        #expect(WKWebView.isAudioMuted(sound))
        #expect(WKWebView.isAudioMuted(sound | devices))
        #expect(!WKWebView.isAudioMuted(devices | screen))
        #expect(!WKWebView.isAudioMuted(0))
    }

    @MainActor @Test func aPageMutesAndUnmutesInWebKit() throws {
        let webView = WKWebView(frame: .zero)
        try #require(webView.pageMutedState != nil)
        #expect(webView.setPageAudioMuted(true) == true)
        #expect(webView.pageMutedState.map(WKWebView.isAudioMuted) == true)
        #expect(webView.setPageAudioMuted(false) == false)
        #expect(webView.pageMutedState.map(WKWebView.isAudioMuted) == false)
    }
}

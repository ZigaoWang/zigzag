import AppKit
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

/// The speaker after a page's title in its sidebar row: shown while it plays or is muted, and a click on it mutes or
/// unmutes that page, in a split the page whose speaker it is.
@MainActor struct RowSpeakerTests {
    private func click(_ button: IconButton) throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        button.onClick?(event)
    }

    private func row(_ tab: Tab, partner: Tab? = nil) -> TabRowView {
        let row = TabRowView(frame: NSRect(x: 0, y: 0, width: 240, height: Tokens.Sidebar.rowHeight))
        row.configure(tab: tab)
        row.configure(parts: [partner].compactMap { $0.map { TabRowView.Part(page: $0) } })
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test func theSpeakerMutesAndUnmutesItsPage() throws {
        let tab = Tab(url: nil, title: "Playing", spaceID: UUID())
        let row = row(tab)
        #expect(row.audioButton.isHidden)
        tab.debugShowSound(playing: true, muted: false)
        row.layoutSubtreeIfNeeded()
        #expect(!row.audioButton.isHidden)
        #expect(row.audioButton.frame.minX > row.title.frame.minX)
        try click(row.audioButton)
        #expect(tab.isMuted)
        #expect(!row.audioButton.isHidden)
        try click(row.audioButton)
        #expect(!tab.isMuted)
    }

    @Test func inASplitEachSpeakerIsItsOwnPages() throws {
        let left = Tab(url: nil, title: "Left", spaceID: UUID()), right = Tab(url: nil, title: "Right", spaceID: UUID())
        let row = row(left, partner: right)
        right.debugShowSound(playing: true, muted: false)
        row.layoutSubtreeIfNeeded()
        #expect(row.audioButton.isHidden)
        #expect(!row.partnerAudioButton.isHidden)
        #expect(row.partnerAudioButton.frame.minX > row.bounds.midX)
        try click(row.partnerAudioButton)
        #expect(right.isMuted && !left.isMuted)
        try click(row.partnerAudioButton)
        #expect(!right.isMuted)
    }
}

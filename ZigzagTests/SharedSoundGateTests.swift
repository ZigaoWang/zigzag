import Testing
import WebKit
@testable import Zigzag

/// A streamed tab's capture hears WebKit's shared sound, which plays every page's: it may hand anything over only
/// while the captured tab is the one page in Zigzag with sound (#45). These are the rules that keep other tabs,
/// private windows, Zigzag Mini and Picture in Picture out of it.
@MainActor
struct SharedSoundGateTests {
    private let captured = SoundSource(isPlaying: true, isCaptured: true)
    private let quietTab = SoundSource(isPlaying: false)
    /// Another page with sound: a tab in this or another window, a private window's, Zigzag Mini's, a pop-up's.
    private let otherPlaying = SoundSource(isPlaying: true)

    // MARK: Which pages count

    @Test func theCapturedTabAloneHasNoCompany() {
        #expect(!SharedSoundGate.othersHaveSound([captured]))
        #expect(!SharedSoundGate.othersHaveSound([captured, quietTab, quietTab]))
        // Even when the captured tab itself is silent.
        #expect(!SharedSoundGate.othersHaveSound([SoundSource(isPlaying: false, isCaptured: true), quietTab]))
    }

    @Test func anyOtherPageWithSoundCounts() {
        // Every web view is one source, whatever window it's in: a tab elsewhere, a private window's, Zigzag Mini's.
        #expect(SharedSoundGate.othersHaveSound([captured, quietTab, otherPlaying]))
        #expect(SharedSoundGate.othersHaveSound([otherPlaying]))
        // Another extension's page (its popup, its background) is no different.
        #expect(SharedSoundGate.othersHaveSound([captured, SoundSource(isPlaying: true, isCapturingExtension: false)]))
    }

    @Test func pictureInPictureCountsEvenBeforeItSaysItPlays() {
        #expect(SharedSoundGate.othersHaveSound([captured, SoundSource(isPlaying: false, isPictureInPicture: true)]))
        // The captured tab floating in Picture in Picture is still just the captured tab.
        #expect(!SharedSoundGate.othersHaveSound([SoundSource(isPlaying: true, isPictureInPicture: true, isCaptured: true)]))
    }

    @Test func theCapturingExtensionsOwnPagesDontCount() {
        // Its offscreen page plays the capture back through Zigzag, and is never another tab.
        let ownPage = SoundSource(isPlaying: true, isCapturingExtension: true)
        #expect(!SharedSoundGate.othersHaveSound([captured, ownPage]))
        #expect(SharedSoundGate.othersHaveSound([captured, ownPage, otherPlaying]))
    }

    /// Every web view Zigzag has is counted where it's made, whoever made it: tabs, private ones, pop-ups, extension
    /// pages, and web views WebKit makes itself, which go through the same `init`.
    @Test func everyWebViewIsCounted() {
        let plain = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let privateConfiguration = WKWebViewConfiguration()
        privateConfiguration.websiteDataStore = .nonPersistent()
        let privateView = WKWebView(frame: .zero, configuration: privateConfiguration)
        let tabView = BrowserWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let live = WebViews.live
        #expect(live.contains { $0 === plain })
        #expect(live.contains { $0 === privateView })
        #expect(live.contains { $0 === tabView })
        let sources = SoundSource.all(capturing: tabView, extensionHost: "abcdefghijklmnopabcdefghijklmnop")
        #expect(sources.count == live.count)
        #expect(sources.filter(\.isCaptured).count == 1)
        // None of these is an extension's page.
        #expect(!sources.contains { $0.isCapturingExtension })
    }

    // MARK: Pausing and carrying on

    @Test func startsOnlyAfterTheTabHasBeenAloneAMoment() {
        var gate = SharedSoundGate([captured], now: 10)
        #expect(gate.aloneSince == 10)
        #expect(!gate.isLive)
        #expect(gate.update([captured], now: 10.2) == nil)
        #expect(!gate.isLive)
        #expect(gate.update([captured], now: 10 + SharedSoundGate.resumeAfter) == .resumed)
        #expect(gate.isLive)
        #expect(gate.update([captured], now: 11) == nil)
    }

    @Test func pausesTheMomentAnotherPageHasSound() {
        var gate = SharedSoundGate([captured], now: 0)
        _ = gate.update([captured], now: 1)
        #expect(gate.isLive)
        #expect(gate.update([captured, otherPlaying], now: 2) == .paused)
        #expect(!gate.isLive)
        #expect(gate.aloneSince == nil)
        // Said once, however long the other page plays.
        #expect(gate.update([captured, otherPlaying], now: 3) == nil)
    }

    @Test func resumesOnlyAfterTheMarginOnceAloneAgain() {
        var gate = SharedSoundGate([captured], now: 0)
        _ = gate.update([captured], now: 1)
        _ = gate.update([captured, otherPlaying], now: 2)
        #expect(gate.update([captured, quietTab], now: 3) == nil)
        #expect(gate.aloneSince == 3)
        #expect(gate.update([captured, quietTab], now: 3.49) == nil)
        #expect(!gate.isLive)
        #expect(gate.update([captured, quietTab], now: 3.5) == .resumed)
        #expect(gate.isLive)
    }

    @Test func aBriefSoundElsewhereStartsTheMarginAgain() {
        var gate = SharedSoundGate([captured], now: 0)
        _ = gate.update([captured], now: 1)
        _ = gate.update([captured, otherPlaying], now: 2)
        _ = gate.update([captured], now: 2.1)
        // Another blip just before it would carry on: the wait starts over.
        #expect(gate.update([captured, otherPlaying], now: 2.55) == .paused)
        #expect(gate.update([captured], now: 2.6) == nil)
        #expect(gate.update([captured], now: 3.0) == nil)
        #expect(gate.update([captured], now: 3.1) == .resumed)
    }

    @Test func beginsPausedWhenAnotherPageAlreadyHasSound() {
        var gate = SharedSoundGate([captured, otherPlaying], now: 0)
        #expect(gate.aloneSince == nil)
        #expect(gate.update([captured, otherPlaying], now: 5) == nil)
        #expect(!gate.isLive)
        #expect(gate.delivery(capturedFrom: 5, to: 5.02, now: 6) == .drop)
        _ = gate.update([captured], now: 6)
        #expect(gate.update([captured], now: 6.5) == .resumed)
    }

    @Test func aPrivateWindowOrMiniPlayingPausesIt() {
        // They're web views like any other: one with sound pauses the capture, wherever it is.
        var gate = SharedSoundGate([captured], now: 0)
        _ = gate.update([captured], now: 1)
        let privateTab = SoundSource(isPlaying: true)
        #expect(gate.update([captured, quietTab, privateTab], now: 2) == .paused)
        _ = gate.update([captured], now: 3)
        _ = gate.update([captured], now: 3.5)
        let miniInPictureInPicture = SoundSource(isPlaying: false, isPictureInPicture: true)
        #expect(gate.update([captured, miniInPictureInPicture], now: 4) == .paused)
    }

    // MARK: Each buffer

    @Test func eachBufferWaitsThenGoesOnlyIfStillAlone() {
        var gate = SharedSoundGate([captured], now: 0)
        _ = gate.update([captured], now: 0.5)
        // Captured after the margin, not yet waited: held.
        #expect(gate.delivery(capturedFrom: 0.6, to: 0.62, now: 0.65) == .wait)
        #expect(gate.delivery(capturedFrom: 0.6, to: 0.62, now: 0.62 + SharedSoundGate.hold - 0.005) == .wait)
        #expect(gate.delivery(capturedFrom: 0.6, to: 0.62, now: 0.62 + SharedSoundGate.hold + 0.001) == .deliver)
        // Captured before the tab had been alone long enough: never.
        #expect(gate.delivery(capturedFrom: 0.4, to: 0.42, now: 1) == .drop)
        // Part of it before the margin ended: never.
        #expect(gate.delivery(capturedFrom: 0.49, to: 0.51, now: 1) == .drop)
    }

    @Test func aBufferHeardAsAnotherPageStartedNeverGoes() {
        var gate = SharedSoundGate([captured], now: 0)
        _ = gate.update([captured], now: 0.5)
        // Heard at 1.00 to 1.02; WebKit says another page plays at 1.05, before the buffer has waited out its hold.
        _ = gate.update([captured, otherPlaying], now: 1.05)
        #expect(gate.delivery(capturedFrom: 1.0, to: 1.02, now: 1.2) == .drop)
        // Alone again, it stays dropped: it was heard before the tab was alone again.
        _ = gate.update([captured], now: 1.3)
        _ = gate.update([captured], now: 1.8)
        #expect(gate.isLive)
        #expect(gate.delivery(capturedFrom: 1.0, to: 1.02, now: 1.9) == .drop)
        #expect(gate.delivery(capturedFrom: 1.79, to: 1.81, now: 1.9) == .drop)
        #expect(gate.delivery(capturedFrom: 1.81, to: 1.83, now: 1.95) == .deliver)
    }

    @Test func theMarginsAreSmallButReal() {
        #expect(SharedSoundGate.hold >= 0.05 && SharedSoundGate.hold <= 0.15)
        #expect(SharedSoundGate.resumeAfter >= 0.5)
    }

    // MARK: The tap

    private final class FakeTap: SharedSoundCapture.Tap {
        var stops = 0
        func stop() { stops += 1 }
    }

    private func chunk(_ from: TimeInterval) -> SharedSoundCapture.Chunk {
        SharedSoundCapture.Chunk(rate: 48000, pcm: "", from: from, until: from + 0.02)
    }

    @Test func theTapRunsOnlyWhileLive() {
        var started: [FakeTap] = []
        let capture = SharedSoundCapture([captured], now: 0) { _ in
            let tap = FakeTap()
            started.append(tap)
            return tap
        }
        // Waiting out the margin: nothing recorded yet.
        #expect(!capture.isHearing)
        capture.update([captured], now: 0.2)
        #expect(started.isEmpty)
        #expect(capture.update([captured], now: 0.5) == .resumed)
        #expect(started.count == 1)
        #expect(capture.isHearing)
        // Another page has sound: the tap goes at once.
        #expect(capture.update([captured, otherPlaying], now: 1) == .paused)
        #expect(started[0].stops == 1)
        #expect(!capture.isHearing)
        capture.update([captured, otherPlaying], now: 2)
        #expect(started.count == 1)
        // Alone a moment again: a new tap.
        capture.update([captured], now: 3)
        capture.update([captured], now: 3.5)
        #expect(started.count == 2)
        // Ended: it goes, and stays gone.
        capture.end()
        #expect(started[1].stops == 1)
        #expect(!capture.isHearing)
    }

    @Test func neverStartsWhileAnotherPageHasSound() {
        var starts = 0
        let capture = SharedSoundCapture([captured, otherPlaying], now: 0) { _ in starts += 1; return FakeTap() }
        for step in 1...20 { capture.update([captured, otherPlaying], now: Double(step) * 0.1) }
        #expect(starts == 0)
        #expect(capture.take(now: 3).isEmpty)
    }

    @Test func pausingDropsEverythingStillWaiting() {
        let capture = SharedSoundCapture([captured], now: 0) { _ in FakeTap() }
        capture.update([captured], now: 0.5)
        capture.receive(chunk(0.6), generation: capture.generation)
        capture.receive(chunk(0.62), generation: capture.generation)
        capture.update([captured], now: 0.65)
        #expect(capture.take(now: 0.65).isEmpty)
        // Another page starts before they've waited out their hold: they never go.
        capture.update([captured, otherPlaying], now: 0.67)
        #expect(capture.take(now: 0.8).isEmpty)
        capture.update([captured], now: 1)
        capture.update([captured], now: 1.5)
        #expect(capture.take(now: 2).isEmpty)
    }

    @Test func handsOverWhatWaitedWhileAlone() {
        let capture = SharedSoundCapture([captured], now: 0) { _ in FakeTap() }
        capture.update([captured], now: 0.5)
        capture.receive(chunk(0.6), generation: capture.generation)
        capture.receive(chunk(0.62), generation: capture.generation)
        capture.update([captured], now: 0.71)
        #expect(capture.take(now: 0.71) == [chunk(0.6)])
        capture.update([captured], now: 0.75)
        #expect(capture.take(now: 0.75) == [chunk(0.62)])
    }

    @Test func whatAnEarlierTapStillSendsIsPassedOver() {
        let capture = SharedSoundCapture([captured], now: 0) { _ in FakeTap() }
        capture.update([captured], now: 0.5)
        let first = capture.generation
        capture.update([captured, otherPlaying], now: 1)
        // Arriving late, from the tap that's been taken down.
        capture.receive(chunk(0.95), generation: first)
        capture.update([captured], now: 2)
        capture.update([captured], now: 2.5)
        #expect(capture.generation != first)
        capture.receive(chunk(0.97), generation: first)
        capture.update([captured], now: 3)
        #expect(capture.take(now: 3).isEmpty)
    }

    @Test func nothingIsKeptOnceEnded() {
        let capture = SharedSoundCapture([captured], now: 0) { _ in FakeTap() }
        capture.update([captured], now: 0.5)
        capture.receive(chunk(0.6), generation: capture.generation)
        capture.end()
        #expect(!capture.isHearing)
        capture.receive(chunk(0.7), generation: capture.generation)
        #expect(capture.take(now: 5).isEmpty)
    }

    @Test func aTapThatCantStartIsReported() {
        struct Refused: Error {}
        let capture = SharedSoundCapture([captured], now: 0) { _ in throw Refused() }
        capture.update([captured], now: 0.5)
        #expect(capture.failure is Refused)
        #expect(!capture.isHearing)
    }
}

import Foundation
import Testing
@testable import Zigzag

/// The "add Zigzag in 1Password" note shows only when every connection is refused; one succeeding cancels it, and unknown replies prove nothing.
struct OnePasswordTrustTests {
    private static func message(_ type: String) -> [String: Any] {
        ["callbackId": 1, "content": ["content": ["type": type, "content": [String: Any]()]]]
    }

    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test func readsTheTypeInsideTheContent() {
        #expect(OnePasswordTrust.type(of: Self.message("BrowserVerificationFailed")) == "BrowserVerificationFailed")
        #expect(OnePasswordTrust.type(of: ["content": ["type": "Success"]]) == nil)
        #expect(OnePasswordTrust.type(of: "hello") == nil)
        #expect(OnePasswordTrust.type(of: [String: Any]()) == nil)
    }

    @Test func onlyTheVerificationFailureTurnsAway() {
        #expect(OnePasswordTrust.reply("BrowserVerificationFailed") == .turnedAway)
        for type in ["Success", "ClientCreated", "LockStateChanged", "AutofillChangeEvent", "AutofillItemUpdated", "SecurityReviewEligibility"] {
            #expect(OnePasswordTrust.reply(type) == .connected)
        }
        // These come whether or not the app trusts Zigzag.
        for type in ["Offline", "AppQuit", "MainAppNotRunning", "MainAppOpenTimeout", "LostConnectionToApp", "Error"] {
            #expect(OnePasswordTrust.reply(type) == .other)
        }
    }

    /// Refused with nothing through: ask, once.
    @Test func turnedAwayWithNothingThroughAsks() {
        var trust = OnePasswordTrust()
        trust.heard(.turnedAway, at: start)
        #expect(!trust.needsAdding(at: start))
        do { let told = trust.tell(at: start.addingTimeInterval(1)); #expect(!told) }
        let later = start.addingTimeInterval(OnePasswordTrust.grace)
        #expect(trust.needsAdding(at: later))
        do { let told = trust.tell(at: later); #expect(told) }
        // Refused again: the note stays, no second toast.
        trust.heard(.turnedAway, at: later.addingTimeInterval(30))
        #expect(trust.needsAdding(at: later.addingTimeInterval(60)))
        do { let told = trust.tell(at: later.addingTimeInterval(60)); #expect(!told) }
    }

    /// One refused while another succeeds: slow app, not untrusted.
    @Test func laterSuccessCancelsATurnAway() {
        var trust = OnePasswordTrust()
        trust.heard(.turnedAway, at: start)
        trust.heard(.connected, at: start.addingTimeInterval(2))
        #expect(!trust.needsAdding(at: start.addingTimeInterval(60)))
        do { let told = trust.tell(at: start.addingTimeInterval(60)); #expect(!told) }
    }

    /// After a trusted connection, a refusal never asks this session; a working 1Password refuses one-off messages too, which showed the note wrongly.
    @Test func aTurnAwayAfterAConnectionNeverAsks() {
        var trust = OnePasswordTrust()
        trust.heard(.connected, at: start)
        trust.heard(.turnedAway, at: start.addingTimeInterval(3600))
        #expect(trust.connected)
        #expect(!trust.needsAdding(at: start.addingTimeInterval(7200)))
        do { let told = trust.tell(at: start.addingTimeInterval(7200)); #expect(!told) }
    }

    /// An unknown reply before a refusal (a handshake) proves nothing; the note still shows.
    @Test func anUnknownReplyIsntTrust() {
        #expect(OnePasswordTrust.reply("HelloThere") == .other)
        var trust = OnePasswordTrust()
        trust.heard(OnePasswordTrust.reply("Handshake"), at: start)
        #expect(!trust.connected)
        trust.heard(.turnedAway, at: start.addingTimeInterval(1))
        #expect(trust.needsAdding(at: start.addingTimeInterval(1 + OnePasswordTrust.grace)))
        // Unknown types logged once a session; known ones never.
        let logged = ["Handshake", "Handshake", "LockStateChanged", "Offline", "BrowserVerificationFailed"].map { trust.isNewUnknown($0) }
        #expect(logged == [true, false, false, false, false])
    }

    /// Added in 1Password after a refusal: the next connection clears the note.
    @Test func addingZigzagClearsTheNote() {
        var trust = OnePasswordTrust()
        trust.heard(.turnedAway, at: start)
        do { let told = trust.tell(at: start.addingTimeInterval(10)); #expect(told) }
        trust.heard(.connected, at: start.addingTimeInterval(120))
        #expect(!trust.needsAdding(at: start.addingTimeInterval(130)))
    }

    /// Offline or not running counts either way.
    @Test func offlineNeitherAsksNorClears() {
        var trust = OnePasswordTrust()
        trust.heard(.other, at: start)
        #expect(!trust.needsAdding(at: start.addingTimeInterval(60)))
        trust.heard(.turnedAway, at: start.addingTimeInterval(60))
        trust.heard(.other, at: start.addingTimeInterval(61))
        #expect(trust.needsAdding(at: start.addingTimeInterval(70)))
        #expect(!trust.connected)
    }
}

/// The "1Password is waiting for you" note follows only your own use of it, never a connect from its background alone.
struct CompanionAppNoticeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func shows(use: TimeInterval?, at now: TimeInterval) -> Bool {
        guard let use else { return false }
        return CompanionAppNotice.follows(use: start.addingTimeInterval(use), waitingSince: start, now: start.addingTimeInterval(now))
    }

    @Test func aClickJustBeforeTheConnectShowsItOnceItHasWaited() {
        #expect(!shows(use: -1, at: 5))
        #expect(shows(use: -1, at: 6))
        #expect(shows(use: -10, at: 6))
    }

    @Test func aBackgroundConnectWithNoUseNeverShowsIt() {
        #expect(!shows(use: nil, at: 6))
        #expect(!shows(use: nil, at: 60))
    }

    @Test func aUseLongBeforeTheConnectDoesNotCount() {
        #expect(!shows(use: -11, at: 6))
        #expect(!shows(use: -300, at: 6))
    }

    @Test func aUseWhileItWaitsCountsForAShortWhile() {
        #expect(shows(use: 30, at: 30))
        #expect(shows(use: 30, at: 46))
        #expect(!shows(use: 30, at: 47))
    }

    @Test func aUseAfterNowDoesNotCount() {
        #expect(!shows(use: 10, at: 9))
    }
}

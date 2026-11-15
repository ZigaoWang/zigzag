import Foundation
import Testing
@testable import Zigzag

/// The note to add Zigzag in 1Password shows only when the 1Password app really turns Zigzag away: not when one
/// connection is turned away while another works, not when a later one gets through, and never again in a session
/// once one has.
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
        for type in ["Success", "ClientCreated", "LockStateChanged", "AutofillChangeEvent", "SecurityReviewEligibility"] {
            #expect(OnePasswordTrust.reply(type) == .connected)
        }
        // Said whether or not the app trusts Zigzag: neither proves it.
        for type in ["Offline", "AppQuit", "MainAppNotRunning", "MainAppOpenTimeout", "LostConnectionToApp", "Error"] {
            #expect(OnePasswordTrust.reply(type) == .other)
        }
    }

    /// Turned away and nothing else: Zigzag needs adding, said once.
    @Test func turnedAwayWithNothingThroughAsks() {
        var trust = OnePasswordTrust()
        trust.heard(.turnedAway, at: start)
        #expect(!trust.needsAdding(at: start))
        do { let told = trust.tell(at: start.addingTimeInterval(1)); #expect(!told) }
        let later = start.addingTimeInterval(OnePasswordTrust.grace)
        #expect(trust.needsAdding(at: later))
        do { let told = trust.tell(at: later); #expect(told) }
        // Turned away again: the note stays, the toast isn't said twice.
        trust.heard(.turnedAway, at: later.addingTimeInterval(30))
        #expect(trust.needsAdding(at: later.addingTimeInterval(60)))
        do { let told = trust.tell(at: later.addingTimeInterval(60)); #expect(!told) }
    }

    /// One connection turned away while another starts and gets through: the app was slow, not untrusting.
    @Test func laterSuccessCancelsATurnAway() {
        var trust = OnePasswordTrust()
        trust.heard(.turnedAway, at: start)
        trust.heard(.connected, at: start.addingTimeInterval(2))
        #expect(!trust.needsAdding(at: start.addingTimeInterval(60)))
        do { let told = trust.tell(at: start.addingTimeInterval(60)); #expect(!told) }
    }

    /// Once anything got through, no turn-away later in the session asks again.
    @Test func neverAsksAfterAConnection() {
        var trust = OnePasswordTrust()
        trust.heard(.connected, at: start)
        trust.heard(.turnedAway, at: start.addingTimeInterval(3600))
        #expect(trust.connected)
        #expect(!trust.needsAdding(at: start.addingTimeInterval(7200)))
        do { let told = trust.tell(at: start.addingTimeInterval(7200)); #expect(!told) }
    }

    /// Added in 1Password after being turned away: the next connection clears the note.
    @Test func addingZigzagClearsTheNote() {
        var trust = OnePasswordTrust()
        trust.heard(.turnedAway, at: start)
        do { let told = trust.tell(at: start.addingTimeInterval(10)); #expect(told) }
        trust.heard(.connected, at: start.addingTimeInterval(120))
        #expect(!trust.needsAdding(at: start.addingTimeInterval(130)))
    }

    /// The app offline or not running doesn't count either way.
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

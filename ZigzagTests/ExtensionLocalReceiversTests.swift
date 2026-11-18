import Foundation
import Testing
@testable import Zigzag

@Suite("ExtensionLocalReceivers")
struct ExtensionLocalReceiversTests {
    @Test func aGrantIsOffUntilItIsRecorded() {
        var state = ExtensionInstalls.State()
        #expect(state.localReceivers == nil)
        state.localReceivers = true
        #expect(state.localReceivers == true)
        state.localReceivers = false
        #expect(state.localReceivers == false)
    }

    @Test func anotherProfileStartsWithTheSameGrant() {
        var state = ExtensionInstalls.State()
        state.localReceivers = true
        #expect(state.carried(enabled: true).localReceivers == true)
        // The grant is a decision about the extension, not about it being on: turning it off doesn't take it back.
        #expect(state.carried(enabled: false).localReceivers == true)
    }

    @Test func theGrantSurvivesWhatIsWritten() throws {
        var state = ExtensionInstalls.State()
        state.localReceivers = true
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ExtensionInstalls.State.self, from: data).localReceivers == true)
        // A record from before the grant reads as none, which is off.
        let old = try JSONDecoder().decode(ExtensionInstalls.State.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(old.localReceivers == nil)
    }
}

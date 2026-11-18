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

    @Test func aLoopbackExtensionRequestKeepsItsMethodHeadersBodyAndCredentials() throws {
        let url = URL(string: "http://localhost:9990/save")!
        let request = try BridgeExtensionFetch.localReceiverRequest(
            ["method": "post", "headers": [["Content-Type", "application/json"], ["X-Token", "abc"]],
             "body": #"{"ok":true}"#, "credentials": "include"], url: url)
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["X-Token"] == "abc")
        #expect(request.body == Data(#"{"ok":true}"#.utf8))
        #expect(request.credentials == .include)
    }

    @Test func aLoopbackExtensionRequestDefaultsToNoCookies() throws {
        let request = try BridgeExtensionFetch.localReceiverRequest([:], url: URL(string: "http://127.0.0.1:1/")!)
        #expect(request.method == "GET")
        #expect(request.credentials == .sameOrigin)
    }

    @Test func aLoopbackExtensionRequestRefusesWhatTheDoorDoesNotCarry() {
        let url = URL(string: "http://localhost:9990/")!
        #expect(throws: (any Error).self) {
            try BridgeExtensionFetch.localReceiverRequest(["method": "TRACE"], url: url)
        }
        #expect(throws: (any Error).self) {
            try BridgeExtensionFetch.localReceiverRequest(
                ["body": String(repeating: "x", count: LocalReceivers.responseLimit + 1)], url: url)
        }
    }

    @Test func aLoopbackAnswerIsWhatTheBridgeExpects() {
        let response = LocalReceivers.Response(url: URL(string: "http://localhost:9990/")!, status: 200,
                                               headers: ["content-type": "application/json"],
                                               body: Data("{}".utf8))
        let answer = BridgeExtensionFetch.localReceiverAnswer(response)
        #expect(answer["status"] as? Int == 200)
        #expect((answer["headers"] as? [[String]]) == [["content-type", "application/json"]])
        #expect((answer["body"] as? String).flatMap { Data(base64Encoded: $0) } == Data("{}".utf8))
        #expect(answer["redirected"] as? Bool == false)
    }
}

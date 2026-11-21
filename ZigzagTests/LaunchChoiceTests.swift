import Foundation
import Testing
@testable import Zigzag

/// Settings › General › On launch (#433): reopening by default, and remembering the choice.
@MainActor
struct LaunchChoiceTests {
    @Test func launchesReopenTheSessionUnlessToldOtherwise() throws {
        let suite = "ZigzagLaunchChoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let shared = LaunchChoice.defaults
        LaunchChoice.defaults = defaults
        defer {
            LaunchChoice.defaults = shared
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(LaunchChoice.choice == .resume)
        LaunchChoice.choice = .fresh
        #expect(LaunchChoice.choice == .fresh)
        // Nothing written, or written by something else: back to reopening.
        defaults.set("nonsense", forKey: LaunchChoice.key)
        #expect(LaunchChoice.choice == .resume)
    }
}

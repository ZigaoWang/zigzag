import Foundation
import Testing
@testable import Zigzag

/// The command bar's rows say each thing once (#135, #136): no open Settings tab under the Settings command, no grey
/// line repeating the title, and Zigzag Mini's recent list without pages that only failed to load.
struct CommandBarRankingTests {
    private final class FakeTab {
        let name: String
        let failed: Bool
        init(_ name: String, failed: Bool = false) { self.name = name; self.failed = failed }
    }

    @Test func settingsTabGivesWayToTheSettingsCommand() {
        let settings = URL(string: "zigzag://settings")!
        let history = URL(string: "zigzag://history")!
        #expect(CommandRanker.repeatsCommand(settings, offered: ["settings", "import"]))
        #expect(CommandRanker.repeatsCommand(history, offered: ["history"]))
        // Without the command among the rows, the open tab is the only way there: it stays.
        #expect(!CommandRanker.repeatsCommand(settings, offered: ["import"]))
        #expect(!CommandRanker.repeatsCommand(URL(string: "https://example.com/settings")!, offered: ["settings"]))
        #expect(!CommandRanker.repeatsCommand(nil, offered: ["settings"]))
    }
}

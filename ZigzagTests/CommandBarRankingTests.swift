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

    @Test func miniLeavesOutPagesThatFailedToLoad() {
        let tabs = [FakeTab("on"), FakeTab("a"), FakeTab("bad", failed: true), FakeTab("b"), FakeTab("cert", failed: true)]
        let mini = CommandRanker.recentChoices(tabs, selected: tabs[0], failed: \.failed, leavingOutFailed: true)
        #expect(mini.map(\.name) == ["a", "b"])
        // A browser window's ⌘T still lists them: switching back to retry one is a fair thing to want there.
        let bar = CommandRanker.recentChoices(tabs, selected: tabs[0], failed: \.failed, leavingOutFailed: false)
        #expect(bar.map(\.name) == ["a", "bad", "b", "cert"])
    }

    @Test func recentListStaysAtSix() {
        let tabs = (0..<10).map { FakeTab("\($0)") }
        #expect(CommandRanker.recentChoices(tabs, selected: nil, failed: \.failed, leavingOutFailed: true).count == 6)
        // The one you're on is left out of the six, as before.
        #expect(CommandRanker.recentChoices(tabs, selected: tabs[2], failed: \.failed, leavingOutFailed: false).map(\.name)
                == ["0", "1", "3", "4", "5"])
    }
}

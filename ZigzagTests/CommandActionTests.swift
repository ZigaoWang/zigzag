import Foundation
import Testing
@testable import Zigzag

/// The command bar's page and window commands: offered only where they'd do something, found by the words you type.
struct CommandActionTests {
    typealias Context = CommandRanker.Context
    let work = Context.Space(id: UUID(), name: "Work")
    let home = Context.Space(id: UUID(), name: "Home Stuff")

    private func titles(_ query: String, _ context: Context) -> [String] {
        CommandRanker.commands(for: query, context: context).map(\.title)
    }

    @Test func onlyANamedCommandLeadsTheSearch() {
        let feedback = CommandRanker.commands(for: "contact", context: Context()).first { $0.title == "Send Feedback…" }
        #expect(feedback != nil)
        #expect(!CommandRanker.isNamed(feedback!, by: ["contact"]))
        let importing = CommandRanker.commands(for: "imp", context: Context()).first { $0.title.hasPrefix("Import") }
        #expect(importing.map { CommandRanker.isNamed($0, by: ["imp"]) } == true)
    }

    private var onATab: Context {
        var c = Context()
        c.hasPage = true
        c.canSplitWithRecent = true
        c.canMove = true
        c.hasOtherTabs = true
        c.spaces = [work, home]
        c.currentSpaceID = work.id
        return c
    }

    @Test func savingFollowsWhatThePageIs() {
        #expect(titles("save", onATab).contains("Pin Tab"))
        #expect(titles("save", onATab).contains("Pin Tab to Folder…"))
        var pinned = onATab
        pinned.isPinned = true
        #expect(titles("save", pinned).contains("Unpin Tab"))
        #expect(!titles("save", pinned).contains("Pin Tab"))
        var favorite = onATab
        favorite.isFavorite = true
        #expect(!titles("save", favorite).contains("Pin Tab"))
        #expect(!titles("fav", favorite).contains("Add to Favorites"))
        var blank = onATab
        blank.hasPage = false
        #expect(titles("save", blank).isEmpty)
    }

    /// A private window adds nothing to Favorites, a pinned page included.
    @Test func aPrivateWindowOffersNoFavorite() {
        #expect(titles("fav", onATab).contains("Add to Favorites"))
        var pinned = onATab
        pinned.isPinned = true
        pinned.isPrivate = true
        #expect(!titles("fav", pinned).contains("Add to Favorites"))
    }

    @Test func splitOrSeparate() {
        #expect(titles("split", onATab).contains("Open in Split View"))
        var split = onATab
        split.inSplit = true
        #expect(titles("split", split) == ["Separate Tabs"])
        var alone = onATab
        alone.canSplitWithRecent = false
        #expect(titles("split", alone).isEmpty)
    }

    @Test func spacesByName() {
        // Only the other spaces, by any word of their names.
        #expect(titles("switch", onATab) == ["Switch to Home Stuff", "Import from Another Browser…"])
        #expect(titles("stuff", onATab) == ["Switch to Home Stuff", "Move to Home Stuff"])
        #expect(titles("move home", onATab) == ["Move to Home Stuff"])
        var pinned = onATab
        pinned.canMove = false
        #expect(titles("move home", pinned).isEmpty)
    }

    @Test func privateWindowsKeepNothing() {
        var c = onATab
        c.isPrivate = true
        #expect(titles("save", c).isEmpty)
        #expect(titles("new space", c).isEmpty)
        #expect(titles("switch", c) == ["Import from Another Browser…"])
    }

    @Test func closeAndReopenOnlyWhenThereIsSomething() {
        #expect(titles("close", onATab) == ["Close Other Tabs"])
        var c = onATab
        c.hasOtherTabs = false
        c.hasTabsBelow = true
        c.canReopen = true
        #expect(titles("close", c) == ["Close Tabs Below", "Reopen Closed Tab"])
        #expect(titles("reopen", c) == ["Reopen Closed Tab"])
    }

    /// Capture… (⇧⌘2) is offered on a page it can take, by its name and by "screenshot" (#457).
    @Test func captureIsOfferedWhereThePageCanBeTaken() {
        var c = onATab
        #expect(!titles("capture", c).contains("Capture…"))
        c.canCapture = true
        #expect(titles("capture", c).contains("Capture…"))
        #expect(titles("screenshot", c).contains("Capture…"))
    }

    @Test func aFirstLetterNeverRunsOne() {
        // "s" then Return searches for s, it doesn't save; the app's own commands still match as before.
        #expect(!titles("s", onATab).contains("Pin Tab"))
        #expect(titles("s", onATab).contains("Settings"))
        #expect(!titles("sa", onATab).contains("Pin Tab"))
        #expect(!titles("cl", onATab).contains("Close Other Tabs"))
        #expect(titles("save", onATab).contains("Pin Tab"))
    }

    @Test func chineseCountsByCharacters() {
        let names = ["固定标签页", "关闭其他标签页", "关闭下方的标签页", "设置"]
        // Two characters are a word; one is when it starts just one name.
        #expect(CommandRanker.isEnough("关闭", for: names))
        #expect(CommandRanker.isEnough("其他", for: names))
        #expect(CommandRanker.isEnough("固", for: names))
        #expect(!CommandRanker.isEnough("关", for: names))
        #expect(!CommandRanker.isEnough("其", for: names))
        // Latin still waits for three, and a Latin letter beside a character counts as Latin.
        #expect(!CommandRanker.isEnough("sa", for: ["Save Page"]))
        #expect(!CommandRanker.isEnough("p固", for: names))
        #expect(CommandRanker.isEnough("save", for: ["Save Page"]))
        #expect(!CommandRanker.isEnough(" ", for: names))
    }
}

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

    @Test func pinFollowsWhatThePageIs() {
        #expect(titles("pin", onATab).contains("Pin Tab"))
        var pinned = onATab
        pinned.isPinned = true
        #expect(titles("pin", pinned).contains("Unpin Tab"))
        #expect(!titles("pin", pinned).contains("Pin Tab"))
        var favorite = onATab
        favorite.isFavorite = true
        #expect(!titles("pin", favorite).contains { $0.hasSuffix("Pin Tab") })
        #expect(!titles("fav", favorite).contains("Add to Favorites"))
        var blank = onATab
        blank.hasPage = false
        #expect(titles("pin", blank).isEmpty)
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
        #expect(titles("pin", c).isEmpty)
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

    @Test func aFirstLetterNeverRunsOne() {
        // "p" then Return searches for p, it doesn't pin; the app's own commands still match as before.
        #expect(!titles("p", onATab).contains("Pin Tab"))
        #expect(titles("p", onATab).contains("Passwords"))
        #expect(titles("pi", onATab).isEmpty)
        #expect(!titles("cl", onATab).contains("Close Other Tabs"))
        #expect(titles("pin", onATab).contains("Pin Tab"))
    }
}

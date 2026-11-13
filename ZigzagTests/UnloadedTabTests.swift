import Foundation
import Testing
@testable import Zigzag

/// A tab whose page isn't running looks the same however it got there: put to sleep, restored after a relaunch and
/// not opened yet, or a pinned page or favorite that isn't open (#205). Its hover card says why.
@MainActor struct UnloadedTabTests {
    private func restored() -> Tab {
        let tab = Tab(url: nil, title: "Example", spaceID: UUID())
        tab.isRestored = true
        return tab
    }

    @Test func aRestoredTabIsNotLoadedAndSaysSo() {
        let tab = restored()
        #expect(!tab.isLoaded)
        #expect(!tab.isAsleep)
        #expect(tab.notLoadedNote == "Not loaded since Zigzag reopened. Loads when you click it.")
    }

    @Test func aRestoredTabNeverClaimsMemoryWasFreed() {
        #expect(restored().notLoadedNote?.contains("Freed") == false)
        #expect(restored().asleepNote == nil)
    }

    @Test func aTabNotLoadedYetForAnotherReasonSaysOnlyThat() {
        let tab = Tab(url: nil, spaceID: UUID())
        #expect(!tab.isLoaded)
        #expect(tab.notLoadedNote == "Not loaded yet. Loads when you click it.")
    }

    @Test func aLoadedTabSaysNothing() {
        let tab = restored()
        tab.ensureWebView()
        #expect(tab.isLoaded)
        #expect(!tab.isRestored)
        #expect(tab.notLoadedNote == nil)
        tab.close()
    }

    @Test func anAsleepTabIsNotLoadedAndSaysWhyItSleeps() {
        let tab = restored()
        tab.ensureWebView()
        tab.suspend(because: "test")
        #expect(tab.isAsleep)
        #expect(!tab.isLoaded)
        // What it says is why it sleeps, never that it was restored.
        #expect(tab.notLoadedNote == tab.asleepNote)
        #expect(tab.notLoadedNote?.hasPrefix("Asleep to save memory.") == true)
    }

    @Test func wokenItIsLoadedAgainAndQuiet() {
        let tab = restored()
        tab.ensureWebView()
        tab.suspend(because: "test")
        tab.ensureWebView()
        #expect(tab.isLoaded)
        #expect(!tab.isAsleep)
        #expect(tab.notLoadedNote == nil)
        tab.close()
    }

    @Test func goingToSleepOrWakingTellsTheRowsAtOnce() {
        let tab = Tab(url: nil, spaceID: UUID())
        var heard: [Bool] = []
        let token = tab.changed.observe { [weak tab] change in if change == .webView, let tab { heard.append(tab.isLoaded) } }
        tab.ensureWebView()
        tab.suspend(because: "test")
        tab.ensureWebView()
        #expect(heard == [true, false, true])
        _ = token
        tab.close()
    }

    @Test func inTheTabsListATabNotRunningWearsTheRing() {
        #expect(TabRowView.ringsUnloaded(pinned: false, loaded: false))
        #expect(!TabRowView.ringsUnloaded(pinned: false, loaded: true))
        // No page at all (a row's empty part): nothing to mark.
        #expect(!TabRowView.ringsUnloaded(pinned: false, loaded: nil))
    }

    @Test func pinnedPagesNotRunningLookLikeOnesNeverOpened() {
        // No ring among pinned pages, loaded or not: the open edge tells them apart.
        #expect(!TabRowView.ringsUnloaded(pinned: true, loaded: false))
        #expect(!TabRowView.ringsUnloaded(pinned: true, loaded: true))
        // Never opened, asleep, or restored and not opened yet: no edge, all alike.
        #expect(!TabRowView.showsOpenEdge(pinned: true, loaded: []))
        #expect(!TabRowView.showsOpenEdge(pinned: true, loaded: [false]))
        #expect(!TabRowView.showsOpenEdge(pinned: true, loaded: [false, false]))
        // The edge only while a page of it is really loaded, either half of a split.
        #expect(TabRowView.showsOpenEdge(pinned: true, loaded: [true]))
        #expect(TabRowView.showsOpenEdge(pinned: true, loaded: [false, true]))
        // A tab's row never has the pinned page's edge.
        #expect(!TabRowView.showsOpenEdge(pinned: false, loaded: [true]))
    }
}

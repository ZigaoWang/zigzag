import AppKit
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

    /// Suspend Page (#342): asleep as Zigzag would put it, said to be your doing, never memory freed.
    @Test func oneYouPutToSleepSaysSo() {
        let tab = restored()
        tab.ensureWebView()
        var refused: [Tab.StaysAwake] = []
        tab.suspend(because: "test", chosen: true) { refused.append($0) }
        #expect(refused.isEmpty)
        #expect(tab.isAsleep && !tab.isLoaded)
        #expect(tab.notLoadedNote == "You put it to sleep. Loads when you click it.")
        #expect(!SleepMemory.note(.chosen, freed: 180 << 20).contains("Freed"))
        tab.ensureWebView()
        #expect(tab.notLoadedNote == nil)
        tab.close()
    }

    @Test func aPageInTheMiniPlayerStaysAwakeAndSaysWhy() {
        let tab = restored()
        tab.ensureWebView()
        tab.isInMiniPlayer = true
        var refused: [Tab.StaysAwake] = []
        tab.suspend(because: "test", chosen: true) { refused.append($0) }
        #expect(refused == [.miniPlayer])
        #expect(tab.isLoaded && !tab.isAsleep)
        #expect(Tab.StaysAwake.miniPlayer.note == "Not put to sleep while it plays in the mini player")
        tab.isInMiniPlayer = false
        tab.close()
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

    private func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// A sleeping tab you click loads again on the page it was on, with its history.
    @Test func aSleepingTabClickedLoadsAgainWhereItWas() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("asleep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.html"), second = folder.appendingPathComponent("second.html")
        try "<title>First</title><p>first".write(to: first, atomically: true, encoding: .utf8)
        try "<title>Second</title><p>second".write(to: second, atomically: true, encoding: .utf8)
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let other = Tab(url: nil, title: "Other", spaceID: space)
        let sleeper = Tab(url: first, title: "First", spaceID: space)
        manager.adopt([other, sleeper], in: space)
        manager.select(sleeper)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        #expect(await until { sleeper.webView?.url == first && sleeper.webView?.isLoading == false })
        sleeper.load(second)
        #expect(await until { sleeper.webView?.url == second && sleeper.webView?.isLoading == false && sleeper.canGoBack })
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep })
        #expect(sleeper.webView == nil)
        // The click on its row selects it.
        manager.select(sleeper)
        #expect(sleeper.isLoaded && !sleeper.isAsleep)
        #expect(await until { sleeper.webView?.url == second && sleeper.canGoBack })
    }

    /// Settings keeps its view when it sleeps, so closing the tab in front of it doesn't rebuild it (#357).
    @Test func aSleepingSettingsTabKeepsItsSettingsView() throws {
        let url = try #require(URL(string: "zigzag://settings"))
        let tab = Tab(url: url, title: "Settings", spaceID: UUID())
        tab.load(url)
        let view = try #require(tab.settingsView)
        tab.suspend(because: "test")
        #expect(tab.settingsView === view)
        tab.close()
    }
}

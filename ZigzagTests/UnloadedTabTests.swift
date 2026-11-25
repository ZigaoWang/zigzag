import AppKit
import Foundation
import Network
import os
import Testing
import WebKit
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

    /// A sleeping tab you click keeps its page's sessionStorage, where a site may keep you signed in (#502), and only
    /// that first page gets it back: the script that puts it back is gone once it has committed.
    @Test func aWokenTabKeepsItsSessionStorage() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("session")
        let (manager, sleeper, other, controller) = try sessionTabs(on: page)
        defer { manager.invalidate(); controller.window?.close() }
        #expect(await until { sleeper.webView?.title == "v1" && sleeper.webView?.isLoading == false })
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep })
        #expect(sleeper.pageState?.session?.items == [["k", "v1"]])
        manager.select(sleeper)
        // Asked for again (the server is on "v2" or later), it still has what the first load kept.
        #expect(await until { server.served >= 2 && sleeper.webView?.isLoading == false && sleeper.webView?.title == "v1" })
        let scripts = sleeper.webView?.configuration.userContentController.userScripts ?? []
        #expect(!scripts.contains { $0.source.hasPrefix(PageState.sessionMark) })
        #expect(sleeper.pageState?.session == nil)
        // The next load starts as any page would: a cleared session stays cleared.
        let before = server.served
        sleeper.webView?.evaluateJavaScript("sessionStorage.clear(); location.reload()", completionHandler: nil)
        #expect(await until { server.served > before && sleeper.webView?.isLoading == false
            && sleeper.webView?.title?.hasPrefix("v") == true && sleeper.webView?.title != "v1" })
    }

    /// WebKit's network process ends while the tab sleeps: the woken page still has its session cookie and sessionStorage.
    @Test func aWokenTabStaysSignedInAfterWebKitsNetworkProcessEnds() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("account")
        let (manager, sleeper, other, controller) = try sessionTabs(on: page)
        defer { manager.invalidate(); controller.window?.close() }
        #expect(await until { sleeper.webView?.title == "out v1" && sleeper.webView?.isLoading == false })
        let store = try #require(sleeper.webView?.configuration.websiteDataStore)
        await NetworkProcessCookies.note(store)
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep })
        let before = NetworkProcessCookies.process(of: store)
        #expect(before > 0)
        store.perform(NSSelectorFromString("_terminateNetworkProcess"))
        #expect(await until { NetworkProcessCookies.process(of: store) != before })
        manager.select(sleeper)
        #expect(await until { server.served >= 2 && sleeper.webView?.isLoading == false && sleeper.webView?.title?.isEmpty == false })
        #expect(sleeper.webView?.title == "in v1")
    }

    /// The same for a page that arrives after its headers: it's put back once the page runs, not lost at the commit.
    @Test func aWokenSlowPageKeepsItsSessionStorage() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("slowsession")
        let (manager, sleeper, other, controller) = try sessionTabs(on: page)
        defer { manager.invalidate(); controller.window?.close() }
        #expect(await until { sleeper.webView?.title == "v1" && sleeper.webView?.isLoading == false })
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep })
        manager.select(sleeper)
        #expect(await until { server.served >= 2 && sleeper.webView?.isLoading == false && sleeper.webView?.title?.isEmpty == false })
        #expect(sleeper.webView?.title == "v1")
        let scripts = sleeper.webView?.configuration.userContentController.userScripts ?? []
        #expect(!scripts.contains { $0.source.hasPrefix(PageState.sessionMark) })
    }

    /// A tab that stays awake when asked to sleep (it's shown again) keeps none of its sessionStorage.
    @Test func aTabThatStaysAwakeKeepsNoSession() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("session")
        let (manager, sleeper, other, controller) = try sessionTabs(on: page)
        defer { manager.invalidate(); controller.window?.close() }
        #expect(await until { sleeper.webView?.title == "v1" && sleeper.webView?.isLoading == false })
        manager.select(other)
        var refused: [Tab.StaysAwake] = []
        sleeper.suspend(because: "test", chosen: true) { refused.append($0) }
        manager.select(sleeper)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!sleeper.isAsleep)
        #expect(sleeper.pageState?.session == nil)
    }

    /// A site's data cleared while its tab sleeps: waking it doesn't bring the sessionStorage back.
    @Test func clearingASitesDataForgetsWhatItsSleepingTabKept() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("session")
        let (manager, sleeper, other, controller) = try sessionTabs(on: page)
        defer { manager.invalidate(); controller.window?.close() }
        #expect(await until { sleeper.webView?.title == "v1" && sleeper.webView?.isLoading == false })
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep && sleeper.pageState?.session != nil })
        let store = try #require(sleeper.privateStore ?? sleeper.profile.storeIfMade)
        sleeper.forgetSession(in: store, site: "example.com")
        #expect(sleeper.pageState?.session != nil, "another site's data")
        sleeper.forgetSession(in: store, site: "128.0.0.1")
        #expect(sleeper.pageState?.session != nil, "another address")
        sleeper.forgetSession(in: store, keeping: ["127.0.0.1"])
        #expect(sleeper.pageState?.session != nil, "a site kept")
        sleeper.forgetSession(in: store, site: "127.0.0.1")
        #expect(sleeper.pageState?.session == nil)
        manager.select(sleeper)
        #expect(await until { sleeper.webView?.isLoading == false && sleeper.webView?.title?.hasPrefix("v") == true
            && sleeper.webView?.title != "v1" })
    }

    /// Zigzag quit and opened again on the last session (an update's restart): the tab's page gets the sessionStorage
    /// it had back before its own scripts first run, with or without its history, and no other page does (#502).
    @Test func aRestoredTabGetsItsSessionStorageBackBeforeItsFirstLoad() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("session")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("restored-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SavedSessionStorage.file(in: folder)
        let (manager, open, other, controller) = try sessionTabs(on: page)
        #expect(await until { open.webView?.title == "v1" && open.webView?.isLoading == false })
        // As Zigzag quits: the open page is read and written down, with a tab saved without its history beside it.
        var read: [UUID: SavedSessionStorage.Saved]?
        SavedSessionStorage.capture([open, other], within: 2) { read = $0 }
        #expect(await until { read != nil })
        let saved = try #require(read?[open.id])
        #expect(read?[other.id] == nil)
        #expect(saved.items == [["k", "v1"]])
        let bare = SavedSessionStorage.Saved(tab: UUID(), url: saved.url, origin: saved.origin, items: [["k", "bare"]])
        SavedSessionStorage.write([saved, bare], to: file)
        let history = open.interactionStateForSaving
        manager.invalidate()
        controller.window?.close()
        open.close()

        // The next launch.
        SavedSessionStorage.prepare(file, resumes: true, profile: open.profile.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let space = Library.shared.spaces[0].id
        let restored = Tab(id: open.id, url: page, title: "Session", spaceID: space, interactionState: history)
        let withoutHistory = Tab(id: bare.tab, url: page, title: "Session", spaceID: space)
        let unrelated = Tab(url: page, title: "Session", spaceID: space)
        for tab in [restored, withoutHistory, unrelated] { SavedSessionStorage.restore(into: tab) }
        SavedSessionStorage.dropWaiting()
        #expect(restored.pageState?.session?.items == [["k", "v1"]])
        #expect(unrelated.pageState == nil)
        let next = TabManager(spaceID: space)
        next.adopt([restored, withoutHistory, unrelated], in: space)
        next.select(restored)
        let window = BrowserWindowController(tabManager: next, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { next.invalidate(); window.window?.close() }
        let served = server.served
        // Asked of the server again, the page's own script found what it had kept on its first run.
        #expect(await until { server.served > served && restored.webView?.isLoading == false && restored.webView?.title == "v1" })
        #expect(restored.pageState?.session == nil)
        next.select(withoutHistory)
        #expect(await until { withoutHistory.webView?.isLoading == false && withoutHistory.webView?.title == "bare" })
        next.select(unrelated)
        #expect(await until { unrelated.webView?.isLoading == false && unrelated.webView?.title?.hasPrefix("v") == true
            && unrelated.webView?.title != "v1" })
    }

    /// A site's data cleared, or the tab closed: what a sleeping tab keeps for the next launch goes too.
    @Test func clearingASitesDataDropsWhatTheNextLaunchWouldGetBack() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("session")
        let (manager, sleeper, other, controller) = try sessionTabs(on: page)
        defer { manager.invalidate(); controller.window?.close() }
        #expect(await until { sleeper.webView?.title == "v1" && sleeper.webView?.isLoading == false })
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep && sleeper.pageState?.session != nil })
        #expect(SavedSessionStorage.entry(for: sleeper)?.items == [["k", "v1"]])
        let store = try #require(sleeper.profile.storeIfMade)
        sleeper.forgetSession(in: store, site: "127.0.0.1")
        #expect(SavedSessionStorage.entry(for: sleeper) == nil)
        // Closed, it keeps nothing either.
        sleeper.close()
        #expect(SavedSessionStorage.entry(for: sleeper) == nil)
    }

    /// Clearing history isn't clearing a site's data: a sleeping tab keeps its sessionStorage, and the saved file stays.
    @Test func clearingHistoryKeepsWhatASleepingTabKept() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("session")
        let (manager, sleeper, other, controller) = try sessionTabs(on: page)
        defer { manager.invalidate(); controller.window?.close() }
        #expect(await until { sleeper.webView?.title == "v1" && sleeper.webView?.isLoading == false })
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep && sleeper.pageState?.session != nil })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SavedSessionStorage.file(in: folder)
        let saved = try #require(SavedSessionStorage.entry(for: sleeper))
        SavedSessionStorage.write([saved], to: file)
        let before = try Data(contentsOf: file)
        _ = HistoryStore(path: ":memory:", profile: sleeper.profile.id).remove()
        #expect(sleeper.pageState?.session?.items == [["k", "v1"]])
        #expect(try Data(contentsOf: file) == before)
    }

    /// The script puts the items back before the page's own scripts run, on its own origin only, and never over a key
    /// the page has.
    @Test func theSessionRestorerKeepsToItsOriginAndTheKeysThere() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let base = try await server.start()
        let page = base.appendingPathComponent("session")
        let origin = String(base.absoluteString.dropLast())
        let quoted = "it's \"quoted\" </script> \u{2028}"
        func title(restoring session: PageState.Session, presetting: String? = nil) async throws -> (String?, Any?) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            if let presetting {
                configuration.userContentController.addUserScript(WKUserScript(source: presetting, injectionTime: .atDocumentStart,
                                                                               forMainFrameOnly: true, in: .page))
            }
            configuration.userContentController.addUserScript(try #require(PageState.sessionRestorer(session)))
            let heard = Heard()
            configuration.userContentController.add(heard, contentWorld: .defaultClient, name: PageState.sessionMessage)
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.load(URLRequest(url: page))
            #expect(await until { webView.title?.isEmpty == false && !webView.isLoading })
            let q = try? await webView.evaluateJavaScript("sessionStorage.getItem('q')")
            // It says it ran only on its own origin.
            #expect(heard.count == (session.origin == origin ? 1 : 0))
            return (webView.title, q)
        }
        let mine = PageState.Session(origin: origin, items: [["k", "kept"], ["q", quoted]])
        let (restored, q) = try await title(restoring: mine)
        #expect(restored == "kept")
        #expect(q as? String == quoted)
        let (elsewhere, _) = try await title(restoring: PageState.Session(origin: "https://a.example", items: [["k", "kept"]]))
        #expect(elsewhere?.hasPrefix("v") == true)
        let (own, _) = try await title(restoring: mine, presetting: "sessionStorage.setItem('k', 'the page')")
        #expect(own == "the page")
    }

    /// Sites are matched by registrable domain, as WebKit keeps their data.
    @Test func sitesAreMatchedAsWebKitKeepsTheirData() {
        #expect(SiteDataListing.site(of: "accounts.example.com") == SiteDataListing.site(of: "app.example.com"))
        #expect(SiteDataListing.site(of: "a.example.com") != SiteDataListing.site(of: "example.org"))
    }

    /// What a page's reader gives back: its sessionStorage only with an origin and something in it.
    @Test func aPageStateReadsItsSession() {
        let url = URL(string: "https://a.example/page")
        let read = PageState(["x": 0.0, "y": 0.0, "session": ["origin": "https://a.example", "items": [["k", "v"], ["bad"]]]], url: url)
        #expect(read?.session == PageState.Session(origin: "https://a.example", items: [["k", "v"]]))
        #expect(read?.withoutSession.session == nil)
        #expect(read?.withoutSession.url == read?.url)
        let empty = PageState(["x": 0.0, "y": 0.0, "session": ["origin": "https://a.example", "items": [[String]]()]], url: url)
        #expect(empty?.session == nil)
        #expect(PageState.reader.contains("sessionStorage") == false, "read only as a tab goes to sleep")
        #expect(PageState.sleepReader.contains("__darkreader__"))
    }

    /// A session with one item too big to carry still keeps the rest: a site's sign-in sits beside a big cache.
    @Test func aBigItemDoesntCostTheRestOfTheSession() async throws {
        let server = try VersionServer()
        defer { server.stop() }
        let page = try await server.start().appendingPathComponent("session")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: page))
        #expect(await until { webView.title == "v1" && !webView.isLoading })
        _ = try await webView.evaluateJavaScript("""
        sessionStorage.setItem('big', 'x'.repeat(300000));
        sessionStorage.setItem('half', 'y'.repeat(150000));
        sessionStorage.setItem('more', 'z'.repeat(150000));
        sessionStorage.setItem('token', 't');
        true
        """)
        let read = try await webView.evaluateJavaScript(PageState.sleepReader, in: nil, contentWorld: .defaultClient)
        let session = try #require(PageState(try #require(read as? [String: Any]), url: page)?.session)
        let keys = Set(session.items.map { $0[0] })
        #expect(keys.isSuperset(of: ["k", "token"]))
        #expect(!keys.contains("big"))
        #expect(keys.intersection(["half", "more"]).count == 1, "the two halves don't both fit")
        #expect(session.items.reduce(0) { $0 + $1[0].count + $1[1].count } <= 250000)
    }

    private final class Heard: NSObject, WKScriptMessageHandler {
        var count = 0
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { count += 1 }
    }

    private func sessionTabs(on page: URL) throws -> (TabManager, Tab, Tab, BrowserWindowController) {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        let other = Tab(url: nil, title: "Other", spaceID: space)
        let sleeper = Tab(url: page, title: "Session", spaceID: space)
        manager.adopt([other, sleeper], in: space)
        manager.select(sleeper)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        return (manager, sleeper, other, controller)
    }

    /// A page you open may start sound on its own; the same page woken from sleep, or restored after a relaunch,
    /// waits for you (#493). Like YouTube, the page tries again once it's shown. The sound is silence.
    @Test func aWokenOrRestoredPageStartsNoSoundOnItsOwn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.silentWAV().write(to: folder.appendingPathComponent("silent.wav"))
        let page = folder.appendingPathComponent("sound.html")
        try """
        <title>waiting</title><audio id="a" loop src="silent.wav"></audio>
        <script>
        const play = () => document.getElementById('a').play().then(() => document.title = 'played', () => document.title = 'blocked ' + document.visibilityState);
        play();
        document.addEventListener('visibilitychange', () => { if (!document.hidden) play(); });
        </script>
        """.write(to: page, atomically: true, encoding: .utf8)
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let other = Tab(url: nil, title: "Other", spaceID: space)
        let sleeper = Tab(url: page, title: "Sound", spaceID: space)
        let restored = Tab(url: page, title: "Sound", spaceID: space)
        restored.isRestored = true
        manager.adopt([other, sleeper, restored], in: space)
        manager.select(sleeper)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        #expect(await until { sleeper.title == "played" })
        // A tab playing sound doesn't sleep, nor one whose sound followed you into the mini player.
        _ = await until { sleeper.isPlayingAudio }
        _ = try await sleeper.webView?.evaluateJavaScript("document.getElementById('a').pause()")
        #expect(await until { !sleeper.isPlayingAudio })
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep })
        manager.select(sleeper)
        #expect(await until { sleeper.title.hasPrefix("blocked") }, "\(sleeper.title)")
        manager.select(restored)
        #expect(await until { restored.title.hasPrefix("blocked") }, "\(restored.title)")
        // Loading it yourself plays as before.
        restored.reload()
        #expect(await until { restored.title == "played" }, "\(restored.title)")
    }

    /// WebKit brings a restored tab's page back from its cache however old, so a page changed since (its site's theme,
    /// a sign-in) came back as it was until reloaded. It's asked of the site again and keeps its history.
    @Test func aRestoredPageIsTheSitesPageNowNotWebKitsOldCopy() async throws {
        let server = try VersionServer()
        let base = try await server.start()
        defer { server.stop() }
        let page = base.appendingPathComponent("page")
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let first = Tab(url: page, title: "Page", spaceID: space)
        manager.adopt([first], in: space)
        manager.select(first)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        #expect(await until { first.title == "v1" }, "\(first.title)")
        let state = try #require(first.interactionStateForSaving)
        let restored = Tab(url: page, title: "Page", spaceID: space, interactionState: state)
        restored.isRestored = true
        manager.adopt([first, restored], in: space)
        manager.select(restored)
        #expect(await until { restored.title == "v2" }, "\(restored.title)")
        #expect(restored.webView?.backForwardList.backList.isEmpty == true)
        #expect(restored.webView?.url == page)
    }

    @Test func onlyARestoredWebPageFetchedWithGetIsAskedAgain() throws {
        let page = try #require(URL(string: "https://example.com/a"))
        #expect(Tab.revalidatesRestoredPage(url: page, method: "GET", type: .backForward))
        #expect(Tab.revalidatesRestoredPage(url: page, method: nil, type: .backForward))
        #expect(!Tab.revalidatesRestoredPage(url: page, method: "POST", type: .backForward))
        #expect(!Tab.revalidatesRestoredPage(url: page, method: "GET", type: .other))
        #expect(!Tab.revalidatesRestoredPage(url: URL(fileURLWithPath: "/tmp/a.html"), method: "GET", type: .backForward))
        #expect(!Tab.revalidatesRestoredPage(url: URL(string: "zigzag://settings"), method: "GET", type: .backForward))
    }

    /// A second of 16-bit mono silence.
    private static func silentWAV() -> Data {
        let rate: UInt32 = 8000, bytes = rate * 2
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        data.append(Data(count: Int(bytes)))
        return data
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

/// `/page` is titled with how many times it was asked for ("v1", "v2"); WebKit keeps it in its cache, stale at once.
nonisolated private final class VersionServer: @unchecked Sendable {
    let listener: NWListener
    private let count = OSAllocatedUnfairLock(initialState: 0)
    /// How many pages it has served.
    var served: Int { count.withLock { $0 } }
    private let queue = DispatchQueue(label: "zigzag.tests.version-server")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue, served = count
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receive(connection, bytes: Data(), served: served)
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { done in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    done.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    done.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private static func receive(_ connection: NWConnection, bytes: Data, served: OSAllocatedUnfairLock<Int>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var bytes = bytes
            if let data { bytes.append(data) }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil && bytes.count < 65536 { receive(connection, bytes: bytes, served: served) } else { connection.cancel() }
                return
            }
            let lines = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let line = lines.first ?? ""
            let path = line.components(separatedBy: " ").dropFirst().first ?? "/"
            let head: String, body: Data
            switch path {
            case "/page":
                let n = served.withLock { $0 += 1; return $0 }
                body = Data("<title>v\(n)</title><p>v\(n)".utf8)
                head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: max-age=0\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            case "/session", "/slowsession":
                // Titled with what its sessionStorage kept: the version first served into it.
                let n = served.withLock { $0 += 1; return $0 }
                body = Data("<title></title><script>sessionStorage.k ||= 'v\(n)'; document.title = sessionStorage.k;</script>".utf8)
                head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            case "/account":
                // Sets a session cookie on the first visit; titled "in" or "out" by the request's cookie, then sessionStorage.
                let n = served.withLock { $0 += 1; return $0 }
                let signedIn = lines.contains { $0.lowercased().hasPrefix("cookie:") && $0.contains("sid=1") }
                body = Data("<title></title><script>sessionStorage.k ||= 'v\(n)'; document.title = '\(signedIn ? "in" : "out") ' + sessionStorage.k;</script>".utf8)
                let cookie = n == 1 ? "Set-Cookie: sid=1; Path=/; HttpOnly\r\n" : ""
                head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\n\(cookie)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            default:
                body = Data("not found".utf8)
                head = "HTTP/1.1 404 Not Found\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            }
            if path == "/slowsession" {
                // Headers first, the page later, as a page streamed from a busy site comes: WebKit commits before it runs.
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                        connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
                    }
                })
                return
            }
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

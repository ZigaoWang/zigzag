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
    private let served = OSAllocatedUnfairLock(initialState: 0)
    private let queue = DispatchQueue(label: "zigzag.tests.version-server")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue, served = served
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
            let line = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let path = line.components(separatedBy: " ").dropFirst().first ?? "/"
            let head: String, body: Data
            switch path {
            case "/page":
                let n = served.withLock { $0 += 1; return $0 }
                body = Data("<title>v\(n)</title><p>v\(n)".utf8)
                head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: max-age=0\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            default:
                body = Data("not found".utf8)
                head = "HTTP/1.1 404 Not Found\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            }
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

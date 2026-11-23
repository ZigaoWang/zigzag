import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A tab that closes or sleeps lets go of its web view, so WebKit can end the page's process and give its memory
/// back (#500). Closed-tab undo keeps only the address and history, never the page.
@MainActor @Suite(.serialized) struct PageReleaseTests {
    private func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func pages() throws -> (folder: URL, first: URL, second: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("first.html"), second = folder.appendingPathComponent("second.html")
        try "<title>First</title><p>first".write(to: first, atomically: true, encoding: .utf8)
        try "<title>Second</title><p>second".write(to: second, atomically: true, encoding: .utf8)
        return (folder, first, second)
    }

    @Test func aClosedTabLetsGoOfItsPageAndItself() async throws {
        let (folder, first, second) = try pages()
        defer { try? FileManager.default.removeItem(at: folder) }
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let other = Tab(url: nil, title: "Other", spaceID: space)
        var closing: Tab? = Tab(url: first, title: "First", spaceID: space)
        manager.adopt([other, closing!], in: space)
        manager.select(closing!)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        defer { controller.window?.close() }
        #expect(await until { closing?.webView?.url == first && closing?.webView?.isLoading == false })
        closing?.load(second)
        #expect(await until { closing?.webView?.url == second && closing?.webView?.isLoading == false })
        weak var page = closing?.webView
        weak var tab = closing
        let id = try #require(closing?.id)
        manager.close(closing!)
        closing = nil
        #expect(await until { page == nil }, "the closed tab's web view is still held")
        #expect(await until { tab == nil }, "the closed tab is still held")
        // ⇧⌘T still brings it back where it was, with its history.
        let back = try #require(manager.reopenClosedTab(id))
        #expect(await until { back.webView?.url == second && back.canGoBack })
    }

    @Test func aSleepingTabLetsGoOfItsPage() async throws {
        let (folder, first, _) = try pages()
        defer { try? FileManager.default.removeItem(at: folder) }
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
        weak var page = sleeper.webView
        manager.select(other)
        sleeper.suspend(because: "test", chosen: true)
        #expect(await until { sleeper.isAsleep })
        #expect(await until { page == nil }, "the sleeping tab's web view is still held")
    }
}

import AppKit
import Testing
import WebKit
@testable import Zigzag

/// Peek hosts its page as a tab does: the pointer and the wheel over the card reach the peeked page, never the page
/// under it (#374).
@MainActor struct PeekHostingTests {
    private func inWindow(_ body: (BrowserWindowController, Tab) throws -> Void) rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let tab = Tab(url: nil, title: "Under", spaceID: space)
        manager.adopt([tab], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(tab)
        _ = tab.ensureWebView()
        controller.window?.layoutIfNeeded()
        try body(controller, tab)
    }

    /// The middle of the peeked page, in window coordinates.
    private func middle(of page: WKWebView) -> NSPoint {
        page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
    }

    @Test func pageUnderTheCardIgnoresThePointerUntilItCloses() throws {
        try inWindow { controller, under in
            let page = try #require(under.webView)
            #expect(page.window != nil)
            #expect(!PeekController.isCovered(page))
            let peeked = try #require(controller.peek.show(url: nil, configuration: nil, opener: under))
            #expect(PeekController.isCovered(page))
            #expect(!PeekController.isCovered(peeked))
            controller.peek.close()
            #expect(!PeekController.isCovered(page))
        }
    }

    /// Shown in another window that shares tabs (#162), the page under the card is clickable there at once; back under
    /// the card, it's covered again.
    @Test func aCoveredPageMovedToAnotherWindowTakesThePointer() throws {
        try inWindow { controller, under in
            let page = try #require(under.webView)
            let holder = try #require(under.pageHolder)
            let home = try #require(holder.superview)
            _ = try #require(controller.peek.show(url: nil, configuration: nil, opener: under))
            #expect(PeekController.isCovered(page))
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            other.contentView?.addSubview(holder)
            #expect(page.window === other)
            #expect(!PeekController.isCovered(page))
            home.addSubview(holder)
            #expect(PeekController.isCovered(page))
            controller.peek.close()
            #expect(!PeekController.isCovered(page))
        }
    }

    /// A page left covered with no Peek over it takes the pointer as soon as it moves.
    @Test func aPageCoveredByNothingIsLetGo() throws {
        try inWindow { _, under in
            let page = try #require(under.webView)
            let holder = try #require(under.pageHolder)
            let home = try #require(holder.superview)
            PeekController.covers(page, true)
            holder.removeFromSuperview()
            home.addSubview(holder)
            #expect(!PeekController.isCovered(page))
        }
    }

    @Test func openingAsTabGivesThePointerBack() throws {
        try inWindow { controller, under in
            let page = try #require(under.webView)
            let peeked = try #require(controller.peek.show(url: nil, configuration: nil, opener: under))
            controller.peek.openAsTab()
            #expect(!PeekController.isCovered(page))
            #expect(!PeekController.isCovered(peeked))
        }
    }

    @Test func theCardsPageIsWhatThePointerHits() throws {
        try inWindow { controller, under in
            let window = try #require(controller.window)
            let peeked = try #require(controller.peek.show(url: nil, configuration: nil, opener: under))
            window.layoutIfNeeded()
            controller.peek.panelView.layoutSubtreeIfNeeded()
            let point = middle(of: peeked)
            let frame = try #require(window.contentView?.superview)
            #expect(frame.hitTest(frame.convert(point, from: nil)) === peeked)
            // Wheel and clicks go to the view hit here; the page under the card ignores the pointer too.
            #expect(PeekController.isCovered(try #require(under.webView)))
            controller.peek.close()
        }
    }

    /// Extensions see a peeked page as a tab of its window, the active one, told as it opens and as it closes.
    @available(macOS 15.4, *)
    @Test func extensionsSeeThePeekAsTheWindowsActiveTab() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try inWindow { controller, under in
            _ = try #require(controller.peek.show(url: nil, configuration: nil, opener: under))
            let peeked = try #require(controller.peek.tab)
            #expect(peeked.toldTo != nil)
            #expect(peeked.toldTo === peeked.extensionHost)
            #expect(peeked.window(for: context) === controller)
            #expect(peeked.isSelected(for: context))
            controller.peek.close()
            #expect(peeked.toldTo == nil)
            #expect(peeked.window(for: context) == nil)
            #expect(under.isSelected(for: context))
        }
    }

    /// Opened as a tab, the peeked page stays the same tab to extensions while it grows; its window gone meanwhile
    /// (this one was never a managed window), it closes for them too.
    @available(macOS 15.4, *)
    @Test func openAsTabKeepsTheExtensionsTabUntilItsWindowGoes() async throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let under = Tab(url: nil, title: "Under", spaceID: space)
        manager.adopt([under], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(under)
        _ = try #require(controller.peek.show(url: nil, configuration: nil, opener: under))
        let peeked = try #require(controller.peek.tab)
        let host = try #require(peeked.toldTo)
        controller.peek.openAsTab()
        #expect(peeked.toldTo === host)
        for _ in 0..<100 where !peeked.isClosed { try await Task.sleep(for: .milliseconds(20)) }
        #expect(peeked.isClosed)
        #expect(peeked.toldTo == nil)
    }

    /// A link followed inside the Peek gives its strip back and forward, which walk the Peek's own pages (#463).
    @Test func aLinkFollowedInPeekShowsBackAndForward() async throws {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let under = Tab(url: nil, title: "Under", spaceID: space)
        manager.adopt([under], in: space)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        defer { controller.window?.close() }
        manager.select(under)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.html"), second = folder.appendingPathComponent("second.html")
        try "<p>First</p>".write(to: first, atomically: true, encoding: .utf8)
        try "<p>Second</p>".write(to: second, atomically: true, encoding: .utf8)

        controller.peek.show(url: first, configuration: nil, opener: under)
        let peeked = try #require(controller.peek.tab)
        let strip = controller.peek.headerView
        for _ in 0..<200 where peeked.isLoading || peeked.url != first { try await Task.sleep(for: .milliseconds(20)) }
        // One page: nothing to go back to, so no buttons.
        #expect(!strip.showsHistory)
        peeked.load(second)
        for _ in 0..<200 where !peeked.canGoBack { try await Task.sleep(for: .milliseconds(20)) }
        #expect(strip.showsHistory)
        #expect(strip.back.isEnabled)
        #expect(!strip.forward.isEnabled)
        strip.layoutSubtreeIfNeeded()
        #expect(strip.icon.frame.minX > strip.forward.frame.maxX)
        // Back, as ⌘[ does while Peek is up: the Peek's page, not the tab under it.
        controller.goBack(nil)
        for _ in 0..<200 where !peeked.canGoForward { try await Task.sleep(for: .milliseconds(20)) }
        #expect(peeked.url?.lastPathComponent == "first.html")
        #expect(strip.showsHistory)
        #expect(!strip.back.isEnabled)
        #expect(strip.forward.isEnabled)
        controller.peek.close()
    }

    @Test func theStripHidesBackAndForwardWithNoHistory() {
        let strip = PeekHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: Tokens.Metric.peekHeaderHeight))
        strip.layoutSubtreeIfNeeded()
        #expect(strip.back.isHidden && strip.forward.isHidden)
        let alone = strip.icon.frame.minX
        strip.showHistory(back: false, forward: true)
        strip.layoutSubtreeIfNeeded()
        #expect(!strip.back.isHidden && !strip.forward.isHidden)
        #expect(!strip.back.isEnabled && strip.forward.isEnabled)
        #expect(strip.icon.frame.minX > alone)
        strip.showHistory(back: false, forward: false)
        #expect(strip.back.isHidden && strip.forward.isHidden)
    }

    /// The strip names a local file by its name, a web page by its host.
    @Test func theStripNamesAFileOrAHost() {
        #expect(PeekController.stripName(for: URL(fileURLWithPath: "/tmp/Notes.html"), title: "Notes") == "Notes.html")
        #expect(PeekController.stripName(for: URL(string: "https://www.example.com/a"), title: "Example") == "example.com")
        #expect(PeekController.stripName(for: nil, title: "Untitled") == "Untitled")
    }
}

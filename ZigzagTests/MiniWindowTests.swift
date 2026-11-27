import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Where a mini window opens, and which links from other apps go to one.
@MainActor
struct MiniWindowTests {
    let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
    let size = NSSize(width: 900, height: 640)

    @Test func firstOneIsCenteredOnTheScreen() {
        let frame = MiniWindowController.frame(size: size, in: screen, taken: [])
        #expect(frame.size == size)
        #expect(frame.midX == screen.midX)
        #expect(abs(frame.midY - screen.midY) <= 0.5)
    }

    @Test func nextOnesCascadeDownAndRight() {
        let first = MiniWindowController.frame(size: size, in: screen, taken: [])
        let second = MiniWindowController.frame(size: size, in: screen, taken: [first])
        let third = MiniWindowController.frame(size: size, in: screen, taken: [first, second])
        #expect(second.minX > first.minX && second.maxY < first.maxY)
        #expect(third.minX > second.minX && third.maxY < second.maxY)
        #expect(second.size == size)
    }

    @Test func aClosedOnesSpotIsUsedAgain() {
        // The first was closed: the second still sits a step down, and the next new one takes the middle again.
        let first = MiniWindowController.frame(size: size, in: screen, taken: [])
        let second = MiniWindowController.frame(size: size, in: screen, taken: [first])
        #expect(MiniWindowController.frame(size: size, in: screen, taken: [second]) == first)
    }

    @Test func smallScreenFitsAndStaysInsideIt() {
        let small = NSRect(x: 0, y: 0, width: 800, height: 500)
        let frame = MiniWindowController.frame(size: size, in: small, taken: [])
        #expect(small.contains(frame))
        #expect(frame.size == NSSize(width: 800, height: 500))
        // No room to cascade: back to the middle rather than off the screen.
        #expect(MiniWindowController.frame(size: size, in: small, taken: [frame]) == frame)
    }

    @Test func onlyWebLinksWithTheSettingOnAfterOnboarding() {
        let web = URL(string: "https://example.com/a")!
        #expect(MiniWindowController.takes(web, settingOn: true, needsOnboarding: false))
        #expect(MiniWindowController.takes(URL(string: "HTTP://example.com")!, settingOn: true, needsOnboarding: false))
        // Off by default, and links before onboarding keep opening in the first window.
        #expect(!MiniWindowController.takes(web, settingOn: false, needsOnboarding: false))
        #expect(!MiniWindowController.takes(web, settingOn: true, needsOnboarding: true))
        // Files opened from Finder stay tabs.
        #expect(!MiniWindowController.takes(URL(fileURLWithPath: "/tmp/page.html"), settingOn: true, needsOnboarding: false))
    }

    /// Every way another app hands over a page ends in `takes` (#246): Apple Event `open location` (Python webbrowser, most apps), document open (`open -a`, Finder), and Handoff.
    @Test func everyLinkFromAnotherAppGoesToZigzagMiniWhenOn() {
        func viaAppleEvent(_ string: String) -> Bool? {
            Scripting.webAddress(string).map { MiniWindowController.takes($0, settingOn: true, needsOnboarding: false) }
        }
        func viaDocument(_ url: URL) -> Bool? {
            AppDelegate.opensAsDocument(url) ? MiniWindowController.takes(url, settingOn: true, needsOnboarding: false) : nil
        }
        // A script's local plot server or another app's OAuth page: Mini.
        #expect(viaAppleEvent("http://127.0.0.1:54123/") == true)
        #expect(viaAppleEvent("https://github.com/login/oauth/authorize?client_id=x") == true)
        #expect(viaDocument(URL(string: "https://accounts.google.com/o/oauth2/auth")!) == true)
        // A file from Finder or `open page.html`: a tab.
        #expect(viaDocument(URL(fileURLWithPath: "/tmp/report.html")) == false)
        // Zigzag, extension and script URLs: nothing opens.
        #expect(viaAppleEvent("zigzag://settings") == nil)
        #expect(viaAppleEvent("javascript:alert(1)") == nil)
        #expect(viaDocument(URL(string: "zigzag://history")!) == nil)
    }

    // MARK: On by default

    @Test func takesLinksFromOtherAppsUnlessTurnedOff() throws {
        let suite = "zigzag-mini-links-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeScratchSuite(suite) }
        // Unset: on, as in Little Arc.
        #expect(MiniWindowController.opensExternalLinks(in: defaults))
        // Turned off in Settings: stays off.
        defaults.set(false, forKey: "OpensExternalLinksInMini")
        #expect(!MiniWindowController.opensExternalLinks(in: defaults))
        defaults.set(true, forKey: "OpensExternalLinksInMini")
        #expect(MiniWindowController.opensExternalLinks(in: defaults))
    }

    @Test func gotItKeepsMiniAndEndsTheNote() throws {
        let suite = "zigzag-mini-links-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeScratchSuite(suite) }
        #expect(MiniWindowController.needsLinksNote(in: defaults))
        MiniWindowController.answerLinksNote(useTabs: false, in: defaults)
        #expect(!MiniWindowController.needsLinksNote(in: defaults))
        #expect(MiniWindowController.opensExternalLinks(in: defaults))
    }

    @Test func useTabsInsteadTurnsMiniOffAndUndoTurnsItBack() throws {
        let suite = "zigzag-mini-links-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeScratchSuite(suite) }
        MiniWindowController.answerLinksNote(useTabs: true, in: defaults)
        #expect(!MiniWindowController.needsLinksNote(in: defaults))
        #expect(!MiniWindowController.opensExternalLinks(in: defaults))
        MiniWindowController.undoUseTabs(in: defaults)
        #expect(MiniWindowController.opensExternalLinks(in: defaults))
        #expect(!MiniWindowController.needsLinksNote(in: defaults))
    }

    // MARK: Open in

    @Test func openInPrefersAWindowOnThisDesktop() {
        // The window last used is on another desktop: the front one here takes the page.
        #expect(MiniWindowController.window(front: "elsewhere", frontToBack: ["elsewhere", "here", "also here"]) { $0.contains("here") && $0 != "elsewhere" } == "here")
        // The one in front is here: it keeps the page.
        #expect(MiniWindowController.window(front: "also here", frontToBack: ["here", "also here"]) { $0.contains("here") } == "also here")
        // None here: nothing chosen, so the one in front is used and Zigzag switches to it.
        #expect(MiniWindowController.window(front: "elsewhere", frontToBack: ["elsewhere", "full screen"]) { _ in false } == nil)
        #expect(MiniWindowController.window(front: nil, frontToBack: ["here"]) { _ in true } == "here")
    }

    // MARK: Its size

    @Test func opensAtTheSizeLastLeftAt() {
        #expect(MiniWindowController.size(remembered: nil) == Tokens.Metric.miniWindowSize)
        #expect(MiniWindowController.size(remembered: NSSize(width: 700.4, height: 820)) == NSSize(width: 700, height: 820))
        // Never below the minimum size.
        #expect(MiniWindowController.size(remembered: NSSize(width: 100, height: 820)) == Tokens.Metric.miniWindowSize)
        #expect(MiniWindowController.size(remembered: .zero) == Tokens.Metric.miniWindowSize)
    }

    // MARK: A page that opens an app (#246)

    @Test func closesOnceItsPageHandedOffToAnApp() {
        // A sign-in page from another app that returns to that app: closes.
        #expect(MiniWindowController.closesAfterOpeningApp(hasPage: true, fromAnotherApp: true, isMainFrame: true, linkClick: false))
        // A link that went straight to an app leaves nothing to show.
        #expect(MiniWindowController.closesAfterOpeningApp(hasPage: false, fromAnotherApp: false, isMainFrame: true, linkClick: true))
        // A clicked mailto: or Open in App link leaves the page open.
        #expect(!MiniWindowController.closesAfterOpeningApp(hasPage: true, fromAnotherApp: true, isMainFrame: true, linkClick: true))
        // A subframe opening an app doesn't close it.
        #expect(!MiniWindowController.closesAfterOpeningApp(hasPage: true, fromAnotherApp: true, isMainFrame: false, linkClick: false))
        // One opened by you stays.
        #expect(!MiniWindowController.closesAfterOpeningApp(hasPage: true, fromAnotherApp: false, isMainFrame: true, linkClick: false))
    }

    // MARK: Back, forward and reload (#213)

    @Test func backAndForwardFollowTheHistory() {
        let strip = MiniStripView()
        strip.showNavigation(canGoBack: false, canGoForward: false, isLoading: false)
        #expect(!strip.backButton.isEnabled && !strip.forwardButton.isEnabled)
        strip.showNavigation(canGoBack: true, canGoForward: false, isLoading: false)
        #expect(strip.backButton.isEnabled && !strip.forwardButton.isEnabled)
        strip.showNavigation(canGoBack: true, canGoForward: true, isLoading: false)
        #expect(strip.backButton.isEnabled && strip.forwardButton.isEnabled)
        strip.showNavigation(canGoBack: false, canGoForward: true, isLoading: false)
        #expect(!strip.backButton.isEnabled && strip.forwardButton.isEnabled)
        // Forward stays in its place, dimmed, as in a browser window: nothing shifts as you go back and forth.
        #expect(!strip.forwardButton.isHidden)
    }

    @Test func reloadIsStopWhileLoading() {
        let strip = MiniStripView()
        strip.showNavigation(canGoBack: false, canGoForward: false, isLoading: true)
        #expect(strip.reloadButton.symbol == "xmark")
        #expect(strip.reloadButton.isEnabled)
        strip.showNavigation(canGoBack: false, canGoForward: false, isLoading: false)
        #expect(strip.reloadButton.symbol == "arrow.clockwise")
    }

    @Test func nothingOverlapsAtAnyWidth() {
        let strip = MiniStripView()
        strip.trafficLightsWidth = 52
        strip.openButton.show("Open in A Space With a Long Name", keys: "⌘O")
        let minimum = Tokens.Metric.miniWindowMinSize.width
        for width in stride(from: minimum, through: 1400, by: 20) {
            strip.frame = NSRect(x: 0, y: 0, width: width, height: Tokens.Metric.miniStripHeight)
            strip.layout()
            let row = [strip.backButton, strip.forwardButton, strip.reloadButton, strip.spaceChip, strip.title,
                       strip.siteButton, strip.pinButton, strip.copyButton, strip.openButton].map(\.frame).filter { $0.width > 0 }
            // Every hover box keeps room from the next, never touching it.
            for (a, b) in zip(row, row.dropFirst()) { #expect(a.maxX + Tokens.Pane.stripGap <= b.minX + 0.5, "at \(width)") }
            #expect(strip.reloadButton.frame.minX > strip.trafficLightsWidth)
            #expect(strip.openButton.frame.maxX <= width)
            // As far from the strip's top as from its bottom, and as from the next box.
            for frame in row {
                #expect(frame.minY == Tokens.Pane.stripGap && strip.bounds.height - frame.maxY == Tokens.Pane.stripGap, "at \(width)")
            }
        }
    }

    /// Editing the address, the field fills the room between the space and the buttons, never under either.
    @Test func theAddressFieldStaysInItsSlot() {
        let strip = MiniStripView()
        strip.trafficLightsWidth = 52
        strip.openButton.show("Open in A Space With a Long Name", keys: "⌘O")
        strip.isEditing = true
        let minimum = Tokens.Metric.miniWindowMinSize.width
        for width in stride(from: minimum, through: 1400, by: 20) {
            strip.frame = NSRect(x: 0, y: 0, width: width, height: Tokens.Metric.miniStripHeight)
            strip.layout()
            let field = strip.anchor.frame
            // Its narrowest; in a window too narrow for that beside the buttons, they step aside for the strip's end.
            #expect(field.width >= MiniStripView.narrowestField, "at \(width)")
            #expect(field.maxX <= width - Tokens.Pane.stripGap, "at \(width)")
            #expect(field.minY == Tokens.Pane.stripGap && field.height == Tokens.Pane.addressHeight, "at \(width)")
            #expect(field.minX >= strip.reloadButton.frame.maxX + Tokens.Space.x2, "at \(width)")
            if !strip.spaceChip.isHidden { #expect(field.minX >= strip.spaceChip.frame.maxX + Tokens.Space.x2, "at \(width)") }
            for button in [strip.siteButton, strip.pinButton, strip.copyButton, strip.openButton] where !button.isHidden {
                #expect(field.maxX + Tokens.Space.x2 <= button.frame.minX + 0.5, "at \(width)")
            }
        }
        // Done editing, everything is back.
        strip.isEditing = false
        strip.frame = NSRect(x: 0, y: 0, width: minimum, height: Tokens.Metric.miniStripHeight)
        strip.layout()
        #expect(!strip.siteButton.isHidden && !strip.pinButton.isHidden && !strip.copyButton.isHidden)
    }

    /// Site Controls (#225) ends the strip's room as it ends the address in a browser window: right before Keep on
    /// Top, with the address field and the site's name kept clear of it, and Open in still as far in from the right
    /// edge as from the top, concentric with the window's corner.
    @Test func siteControlsComeBeforeKeepOnTop() {
        let strip = MiniStripView()
        strip.trafficLightsWidth = 52
        strip.openButton.show("Open in Personal", keys: "⌘O")
        for width in [Tokens.Metric.miniWindowMinSize.width, 640, 900, 1400] {
            strip.frame = NSRect(x: 0, y: 0, width: width, height: Tokens.Metric.miniStripHeight)
            strip.layout()
            #expect(strip.siteButton.frame.width > 0, "at \(width)")
            #expect(strip.siteButton.frame.maxX + Tokens.Pane.stripGap == strip.pinButton.frame.minX, "at \(width)")
            #expect(strip.title.frame.width == 0 || strip.title.frame.maxX <= strip.siteButton.frame.minX + 0.5, "at \(width)")
            // Concentric with the window's corner: as far in from the right as from the top.
            #expect(strip.openButton.frame.maxX == width - strip.openButton.frame.minY, "at \(width)")
        }
    }
}

/// Zigzag Mini opened from a link on a page: over that window, in the page's profile and privacy, and ⌘O puts the
/// page right after the tab it came from.
@MainActor
struct MiniFromPageTests {
    private func inWindow(isPrivate: Bool = false, _ body: (BrowserWindowController, Tab) async throws -> Void) async rethrows {
        let space = Library.shared.spaces[0].id
        let before = Library.shared.snapshot
        let manager = TabManager(spaceID: space, isPrivate: isPrivate)
        defer { manager.invalidate(); Library.shared.restore(before) }
        let first = manager.newTab(url: nil, spaceID: space)
        let source = manager.newTab(url: nil, spaceID: space)
        _ = manager.newTab(url: nil, spaceID: space, select: false)
        _ = first
        manager.select(source)
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 100, y: 100, width: 1000, height: 700))
        defer { controller.window?.close() }
        controller.window?.orderBack(nil)
        controller.window?.layoutIfNeeded()
        try await body(controller, source)
    }

    @Test func itOpensOverTheWindowsPage() async throws {
        try await inWindow { controller, source in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: source, in: controller)
            defer { mini.window?.close() }
            let window = try #require(controller.window)
            let root = controller.root
            let page = window.convertToScreen(root.convert(root.cardFrame, to: nil))
            let frame = try #require(mini.window?.frame)
            let area = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
            #expect(area.contains(frame))
            #expect(frame.size == MiniWindowController.openingSize || frame.width <= area.width)
            // Centered on the page as far as the screen allows.
            if area.insetBy(dx: 1, dy: 1).contains(NSRect(x: page.midX - frame.width / 2, y: page.midY - frame.height / 2, width: frame.width, height: frame.height)) {
                #expect(abs(frame.midX - page.midX) <= 1 && abs(frame.midY - page.midY) <= 1)
            }
            #expect(mini.fromPage && mini.source === controller)
            #expect(mini.tab.spaceID == controller.tabManager.currentSpaceID)
            #expect(!mini.isPrivate)
        }
    }

    @Test func aPrivateWindowsMiniIsPrivate() async throws {
        try await inWindow(isPrivate: true) { controller, source in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: source, in: controller)
            defer { mini.window?.close() }
            #expect(mini.isPrivate)
            let store = try #require(mini.tab.webView?.configuration.websiteDataStore)
            #expect(!store.isPersistent)
            #expect(store === controller.tabManager.privateStore)
            #expect(mini.savedForRelaunch == nil)
            // Open in names the private window, not a space the page won't go to.
            let place = String(localized: "Private", comment: "The heading at the top of a private window's sidebar, where a space's name would be.")
            #expect(mini.debugState["open"] as? String == String(localized: "Open in \(place)", comment: "The button in Zigzag Mini's top strip, and the File menu item in place of Open File… while it's in front: moves its page into a browser window as a tab, in this space. The placeholder is the space's name."))
        }
    }

    @Test func openInZigzagPutsItRightAfterTheTabItCameFrom() async throws {
        try await inWindow { controller, source in
            let manager = controller.tabManager
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
            try "<p>Mini</p>".write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let mini = MiniWindowController.open(fromPage: file, configuration: nil, opener: source, in: controller)
            let page = mini.tab
            for _ in 0..<200 where page.url == nil { try await Task.sleep(for: .milliseconds(20)) }
            mini.openInZigzag()
            for _ in 0..<200 where !manager.tabs(in: manager.currentSpaceID).contains(where: { $0 === page }) { try await Task.sleep(for: .milliseconds(20)) }
            let list = manager.tabs(in: manager.currentSpaceID)
            let at = try #require(list.firstIndex { $0 === source })
            #expect(list.indices.contains(at + 1) && list[at + 1] === page)
            #expect(manager.selectedTab === page)
            // The same live page, never reloaded.
            #expect(page.webView != nil && !page.isClosed)
        }
    }

    /// Minimized or hidden, the window it came from still takes its pages, its new tabs and its translating.
    @Test func aHiddenSourceWindowStillTakesItsPages() async throws {
        try await inWindow(isPrivate: true) { controller, source in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: source, in: controller)
            defer { mini.window?.close() }
            controller.window?.orderOut(nil)
            #expect(controller.window?.isVisible == false)
            #expect(mini.browserTarget === controller)
            #expect(mini.translator === controller)
            #expect(mini.browserTarget.tabManager.privateStore === mini.tab.privateStore)
        }
        try await inWindow { controller, source in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: source, in: controller)
            defer { mini.window?.close() }
            controller.window?.orderOut(nil)
            #expect(mini.browserTarget === controller)
            // Closed, it's no longer where the pages go.
            controller.window?.close()
            #expect(mini.translator !== controller)
        }
    }

    @Test func aTabFromOutsideGoesRightAfterItsAnchor() {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let a = manager.newTab(url: nil, spaceID: space)
        let b = manager.newTab(url: nil, spaceID: space)
        let page = Tab(url: nil, spaceID: space)
        #expect(manager.insert(page, after: a))
        let list = manager.tabs(in: space)
        #expect(list.firstIndex { $0 === page } == list.firstIndex { $0 === a }.map { $0 + 1 })
        #expect(list.contains { $0 === b })
        // An anchor that isn't in the space in front: nothing placed.
        #expect(!manager.insert(Tab(url: nil, spaceID: space), after: Tab(url: nil, spaceID: space)))
    }

    /// The pointer and the wheel over the Mini reach its page: it's what a click in the middle of the window hits.
    @Test func theMinisPageIsWhatThePointerHits() async throws {
        try await inWindow { controller, source in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: source, in: controller)
            defer { mini.window?.close() }
            let window = try #require(mini.window)
            let page = try #require(mini.tab.webView)
            window.layoutIfNeeded()
            let frame = try #require(window.contentView?.superview)
            let point = page.convert(NSPoint(x: page.bounds.midX, y: page.bounds.midY), to: nil)
            #expect(frame.hitTest(frame.convert(point, from: nil)) === page)
        }
    }

    /// Extensions see a Mini from a page as a window with one active tab, told as it opens and as it closes (#374);
    /// a private one only to extensions allowed in private windows.
    @available(macOS 15.4, *)
    @Test func extensionsSeeTheMiniAsAWindowWithOneActiveTab() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"manifest_version":3,"name":"Probe","version":"1.0"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try await inWindow { controller, source in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: source, in: controller)
            let page = mini.tab
            #expect(page.toldTo != nil && page.toldTo === page.extensionHost)
            #expect(page.window(for: context) === mini)
            #expect(page.isSelected(for: context))
            #expect(mini.tabs(for: context).count == 1)
            #expect(!mini.isPrivate(for: context))
            mini.window?.close()
            #expect(page.toldTo == nil)
        }
        try await inWindow(isPrivate: true) { controller, source in
            let mini = MiniWindowController.open(fromPage: nil, configuration: nil, opener: source, in: controller)
            defer { mini.window?.close() }
            #expect(mini.isPrivate(for: context))
            #expect(mini.tabs(for: context).isEmpty && mini.activeTab(for: context) == nil)
        }
    }

    /// A link followed inside the Mini turns Back on, which walks the Mini's own pages (#463).
    @Test func aLinkFollowedInTheMiniGoesBackAndForward() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.html"), second = folder.appendingPathComponent("second.html")
        try "<p>First</p>".write(to: first, atomically: true, encoding: .utf8)
        try "<p>Second</p>".write(to: second, atomically: true, encoding: .utf8)
        try await inWindow { controller, source in
            let mini = MiniWindowController.open(fromPage: first, configuration: nil, opener: source, in: controller)
            defer { mini.window?.close() }
            let page = mini.tab
            for _ in 0..<200 where page.isLoading || page.url != first { try await Task.sleep(for: .milliseconds(20)) }
            #expect(mini.debugState["backEnabled"] as? Bool == false)
            page.load(second)
            for _ in 0..<200 where !page.canGoBack { try await Task.sleep(for: .milliseconds(20)) }
            #expect(mini.debugState["backEnabled"] as? Bool == true)
            #expect(mini.debugState["forwardEnabled"] as? Bool == false)
            mini.goBack(nil)
            for _ in 0..<200 where !page.canGoForward { try await Task.sleep(for: .milliseconds(20)) }
            #expect(page.url?.lastPathComponent == "first.html")
            #expect(mini.debugState["forwardEnabled"] as? Bool == true)
            // The tab it came from stays where it was.
            #expect(controller.tabManager.selectedTab === source)
        }
    }

    /// The strip names a local file by its name, a web page by its site.
    @Test func theStripNamesAFileOrASite() {
        let title = MiniTitleView()
        title.show(Tab(url: URL(fileURLWithPath: "/tmp/Notes.html"), title: "Notes", spaceID: UUID()))
        #expect(title.text == "Notes.html")
        title.show(Tab(url: URL(string: "https://www.example.com/a"), title: "Example", spaceID: UUID()))
        #expect(title.text.contains("example.com"))
    }
}

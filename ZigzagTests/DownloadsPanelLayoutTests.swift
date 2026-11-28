import AppKit
import Foundation
import Testing
@testable import Zigzag

/// The downloads panel is as wide as its labels need (#430): at the narrowest sidebar, in English and Chinese, every
/// label gets at least its own width.
@MainActor struct DownloadsPanelLayoutTests {
    private static let keys = (title: "Downloads", empty: "Nothing downloaded yet", open: "Open Downloads Folder", showAll: "Show All Downloads")

    private func words(_ language: String) throws -> (String, String, String, String) {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let k = Self.keys
        let t = { (key: String) in bundle.localizedString(forKey: key, value: nil, table: nil) }
        return (t(k.title), t(k.empty), t(k.open), t(k.showAll))
    }

    @Test(arguments: ["en", "zh-Hans"]) func everyLabelFitsAtTheNarrowestSidebar(language: String) throws {
        let space = Library.shared.spaces[0].id
        let manager = TabManager(spaceID: space)
        defer { manager.invalidate() }
        let controller = BrowserWindowController(tabManager: manager, frame: NSRect(x: 0, y: 0, width: Tokens.Metric.windowMinSize.width, height: 600))
        defer { controller.window?.close() }
        controller.root.sidebarWidth = Tokens.Metric.sidebarMinWidth
        controller.root.layoutSubtreeIfNeeded()
        let panel = DownloadsPanelView(controller: controller)
        panel.show(from: controller.sidebar.downloadsAnchor)
        defer { panel.close() }
        let (title, empty, open, showAll) = try words(language)
        for folder in [open, showAll] {
            // Each wording of the last row in turn, as the one shown.
            panel.debugRelabel(title: title, empty: empty, open: folder, showAll: folder)
            #expect(panel.frame.width >= panel.fittingWidth)
            for label in panel.debugLabels {
                #expect(label.given >= label.needs, "\(language) \(label.name): \(label.given) < \(label.needs)")
            }
        }
        // Within the window.
        let overlay = controller.root.overlay.bounds
        #expect(panel.frame.minX >= 0 && panel.frame.maxX <= overlay.maxX)
    }

    /// Settings sets the menu of where downloads go each time its window comes forward: the folder's name and icon
    /// are asked of Launch Services once, not each time.
    @Test func theDownloadsFolderIsLookedUpOnce() {
        let button = DropdownButton()
        DownloadPlace.configure(button)
        let asked = DownloadPlace.lookups
        for _ in 0..<5 { DownloadPlace.configure(button) }
        _ = DownloadPlace.shown(DownloadManager.folder)
        #expect(DownloadPlace.lookups == asked)
        #expect(button.options.first?.title == FileManager.default.displayName(atPath: DownloadManager.folder.path))
        // Another folder is looked up afresh.
        let other = FileManager.default.temporaryDirectory
        #expect(DownloadPlace.shown(other).name == FileManager.default.displayName(atPath: other.path))
        #expect(DownloadPlace.lookups == asked + 1)
    }
}

/// The downloads panel lists the newest first and keeps earlier ones behind Show All Downloads (#586).
@MainActor struct DownloadsPanelListTests {
    private let now = Date()

    /// A download in this state, started this many minutes ago; lists have the newest first, as the manager does.
    private func item(_ name: String, _ state: DownloadItem.State, minutesAgo: Double) -> DownloadItem {
        let item = DownloadItem(filename: name, sourceURL: nil, isPrivate: false)
        DownloadManager.shared.debugSetState(state, of: item)
        item.started = now.addingTimeInterval(-minutesAgo * 60)
        return item
    }

    @Test func aFinishedDownloadIsShownAloneWithTheRestBehindShowAll() {
        let new = item("new.zip", .finished, minutesAgo: 0)
        let earlier = [item("old.pdf", .finished, minutesAgo: 2), item("older.dmg", .finished, minutesAgo: 600)]
        let shown = DownloadsPanelView.shown([new] + earlier, focused: new, showingAll: false, now: now)
        #expect(shown.items.map(\.filename) == ["new.zip"])
        #expect(shown.more)
        // One still coming in shows beside it.
        let coming = item("coming.iso", .downloading, minutesAgo: 1)
        #expect(DownloadsPanelView.shown([new, coming] + earlier, focused: new, showingAll: false, now: now).items.map(\.filename) == ["new.zip", "coming.iso"])
        // The only download: nothing more to show, so the last row opens the folder.
        #expect(!DownloadsPanelView.shown([new], focused: new, showingAll: false, now: now).more)
    }

    @Test func openedYourselfItListsTheRecentOnesNewestFirst() {
        let all = [item("a", .finished, minutesAgo: 1), item("b", .failed, minutesAgo: 30), item("c", .paused, minutesAgo: 300),
                   item("d", .finished, minutesAgo: 120), item("e", .finished, minutesAgo: 2000)]
        let shown = DownloadsPanelView.shown(all, focused: nil, showingAll: false, now: now)
        #expect(shown.items.map(\.filename) == ["a", "b", "c"])
        #expect(shown.more)
        // Nothing recent: the newest alone.
        let old = [item("x", .finished, minutesAgo: 500), item("y", .finished, minutesAgo: 900)]
        #expect(DownloadsPanelView.shown(old, focused: nil, showingAll: false, now: now).items.map(\.filename) == ["x"])
        // At most five recent ones.
        let many = (0..<8).map { item("\($0)", .finished, minutesAgo: Double($0)) }
        #expect(DownloadsPanelView.shown(many, focused: nil, showingAll: false, now: now).items.count == DownloadsPanelView.recentCount)
    }

    @Test func showAllListsAsManyAsFitNewestFirst() {
        let all = (0..<20).map { item("\($0)", .finished, minutesAgo: Double($0) * 90) }
        let roomy = DownloadsPanelView.shown(all, focused: nil, showingAll: true, room: DownloadsPanelView.allCount, now: now)
        #expect(roomy.items.map(\.filename) == (0..<DownloadsPanelView.allCount).map { "\($0)" })
        #expect(!roomy.more)
        // A short window still lists the five newest.
        #expect(DownloadsPanelView.shown(all, focused: nil, showingAll: true, room: 2, now: now).items.count == DownloadsPanelView.recentCount)
    }
}

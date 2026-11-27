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

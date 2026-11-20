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
}

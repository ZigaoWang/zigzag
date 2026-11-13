import Foundation
import Testing
@testable import Zigzag

/// Extensions that come inside apps (#194): found in an app's Resources and in the apps one level inside it, never
/// deeper, and only a folder whose manifest.json says it's an extension. Made-up apps in a folder of their own, so the
/// Mac's real Applications is never looked at.
struct AppBundledExtensionsTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-app-extensions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func manifest(_ version: Int = 3, name: String = "Madness") -> String {
        #"{"manifest_version": \#(version), "name": "\#(name)", "version": "1.0"}"#
    }

    @Test func findsOneInsideAHelperApp() throws {
        let apps = try makeFolder()
        defer { try? FileManager.default.removeItem(at: apps) }
        // As StopTheMadness Pro ships it.
        let folder = apps.appendingPathComponent("StopTheMadness Pro.app/Contents/MacOS/StopTheMadness Chrome.app/Contents/Resources/chromium", isDirectory: true)
        try write(manifest(), to: folder.appendingPathComponent("manifest.json"))
        let found = AppBundledExtensions.find(in: apps)
        #expect(found.count == 1)
        #expect(found.first?.folder.standardizedFileURL == folder.standardizedFileURL)
        #expect(found.first?.appName == "StopTheMadness Pro")
        #expect(AppBundledExtensions.app(containing: folder.path) == "StopTheMadness Pro")
    }

    @Test func findsOneInAnAppsOwnResources() throws {
        let apps = try makeFolder()
        defer { try? FileManager.default.removeItem(at: apps) }
        try write(manifest(2), to: apps.appendingPathComponent("Helper.app/Contents/Resources/extension/manifest.json"))
        try write(manifest(), to: apps.appendingPathComponent("Other.app/Contents/Resources/Inside.app/Contents/Resources/chrome/manifest.json"))
        #expect(AppBundledExtensions.find(in: apps).map(\.appName) == ["Helper", "Other"])
    }

    @Test func leavesEverythingElse() throws {
        let apps = try makeFolder()
        defer { try? FileManager.default.removeItem(at: apps) }
        let resources = apps.appendingPathComponent("Plain.app/Contents/Resources", isDirectory: true)
        // Not an extension's manifest: no manifest_version, an unknown one, no name, or not JSON.
        try write(#"{"name": "Web App", "start_url": "/"}"#, to: resources.appendingPathComponent("webapp/manifest.json"))
        try write(manifest(7), to: resources.appendingPathComponent("future/manifest.json"))
        try write(#"{"manifest_version": 3}"#, to: resources.appendingPathComponent("nameless/manifest.json"))
        try write("not json", to: resources.appendingPathComponent("broken/manifest.json"))
        // Too deep, a language's folder, a Safari extension's plug-in, a file at the top, an app outside Applications' top.
        try write(manifest(), to: resources.appendingPathComponent("a/b/manifest.json"))
        try write(manifest(), to: resources.appendingPathComponent("en.lproj/manifest.json"))
        try write(manifest(), to: apps.appendingPathComponent("Plain.app/Contents/PlugIns/Ext.appex/Contents/Resources/manifest.json"))
        try write(manifest(), to: resources.appendingPathComponent("manifest.json"))
        try write(manifest(), to: apps.appendingPathComponent("Utilities/Deep.app/Contents/Resources/chromium/manifest.json"))
        // Two levels of apps inside an app is one too many.
        try write(manifest(), to: apps.appendingPathComponent("Nest.app/Contents/MacOS/One.app/Contents/MacOS/Two.app/Contents/Resources/chromium/manifest.json"))
        #expect(AppBundledExtensions.find(in: apps).isEmpty)
    }

    @Test func nothingWhereThereAreNoApps() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-no-such-\(UUID().uuidString)")
        #expect(AppBundledExtensions.find(in: missing).isEmpty)
        #expect(AppBundledExtensions.app(containing: "/Users/me/Code/my-extension") == nil)
    }

    /// Installed from an app, its ID comes from the folder's path, so the same folder is the same extension.
    @MainActor
    @Test func theSameFolderIsTheSameExtension() {
        let folder = URL(fileURLWithPath: "/Applications/StopTheMadness Pro.app/Contents/MacOS/StopTheMadness Chrome.app/Contents/Resources/chromium")
        #expect(ExtensionStore.unpackedID(for: folder) == ExtensionStore.unpackedID(for: folder.appendingPathComponent(".").standardizedFileURL))
        #expect(ExtensionStore.unpackedID(for: folder) != ExtensionStore.unpackedID(for: folder.deletingLastPathComponent()))
        #expect(ExtensionStore.unpackedID(for: folder).count == 32)
    }
}

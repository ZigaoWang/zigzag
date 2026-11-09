import Foundation
import Testing
@testable import Zigzag

/// What keeps an extension inside its lines: the files its package may hold, and what Zigzag opens for it.
@MainActor
struct ExtensionSecurityTests {
    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExtensionSecurityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Zips a folder's contents as a package would be, with ditto, which keeps symbolic links as links.
    private static func zip(_ folder: URL, to file: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, file.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
    }

    @Test func packageOfPlainFilesUnpacks() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("icons"), withIntermediateDirectories: true)
        try Data(#"{"version": "1.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("png".utf8).write(to: source.appendingPathComponent("icons/16.png"))
        let file = work.appendingPathComponent("package.zip")
        try Self.zip(source, to: file)

        let out = work.appendingPathComponent("out")
        #expect(ExtensionStore.extract(file, into: out))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("icons/16.png").path))
    }

    @Test func packageWithASymbolicLinkIsRefused() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"version": "1.0"}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))
        // A link to a file outside the package, which the extension could then fetch as one of its own.
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("hosts.txt").path, withDestinationPath: "/etc/hosts")
        let file = work.appendingPathComponent("package.zip")
        try Self.zip(source, to: file)

        let out = work.appendingPathComponent("out")
        #expect(!ExtensionStore.extract(file, into: out))
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func folderWithALinkedFolderOrHardLinkIsRefused() throws {
        let work = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let outside = work.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside)

        let linkedFolder = work.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkedFolder.appendingPathComponent("up").path, withDestinationPath: work.path)
        #expect(!ExtensionStore.holdsOnlyItsOwnFiles(linkedFolder))

        let hardLinked = work.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: hardLinked, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: outside, to: hardLinked.appendingPathComponent("copy.txt"))
        #expect(!ExtensionStore.holdsOnlyItsOwnFiles(hardLinked))

        let plain = work.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: plain.appendingPathComponent("nested/file.js"))
        #expect(ExtensionStore.holdsOnlyItsOwnFiles(plain))
    }

    @Test func onlyAServiceWorkerGetsTheSocketStandIn() {
        #expect(ExtensionProfile.usesWebSocketShim(manifest: ["background": ["service_worker": "background.js"]]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: ["background": ["scripts": ["background.js"]]]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: ["background": ["page": "background.html"]]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: ["name": "No background"]))
        #expect(!ExtensionProfile.usesWebSocketShim(manifest: nil))
    }
}

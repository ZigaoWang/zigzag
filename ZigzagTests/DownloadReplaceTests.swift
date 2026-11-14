import Foundation
import Testing
@testable import Zigzag

/// A download that's to replace what's at its name (an extension's "overwrite") only ever replaces a plain file:
/// never a folder, a package or a link.
struct DownloadReplaceTests {
    @Test func onlyAPlainFileIsReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zz-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        let folder = dir.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(DownloadManager.isPlainFile(file))
        #expect(!DownloadManager.isPlainFile(folder))
        #expect(!DownloadManager.isPlainFile(link))
        #expect(!DownloadManager.isPlainFile(dir.appendingPathComponent("missing")))
    }
}

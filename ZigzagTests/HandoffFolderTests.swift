import Foundation
import Testing
@testable import Zigzag

/// A File handoff's download waits in the system's temporary folder, not in Downloads (#589): it is a carrier for
/// the app or service, macOS clears that folder, and it is still there to be found if you want it — which is the
/// difference from deleting it after the handoff.
struct HandoffFolderTests {
    /// The folder exists after asking for it, it is the system's temporary folder, and only its owner may look in.
    @Test func theHandoffFolderIsInTheSystemTemporaryFolderAndPrivate() throws {
        let folder = DownloadManager.handoffFolder
        defer { try? FileManager.default.removeItem(at: folder) }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder))
        #expect(isFolder.boolValue)
        #expect(folder.lastPathComponent == "Handoffs")
        // Under the user's own temporary folder, which macOS empties.
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(folder.standardizedFileURL.path.hasPrefix(temp))
        let mode = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700, "only you may read what an app was handed")
    }

    /// Asking twice is the same folder, and files already in it are not disturbed: a second handoff arriving while
    /// the first is still waiting must not clear the first's file.
    @Test func askingAgainKeepsTheFolderAndItsFiles() throws {
        let folder = DownloadManager.handoffFolder
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appendingPathComponent("waiting.torrent")
        try Data("torrent".utf8).write(to: kept)
        #expect(DownloadManager.handoffFolder == folder)
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    /// A name already taken in the handoff folder gets one of its own, as anywhere else: two handoffs of the same
    /// metafile name would otherwise be one file handed twice.
    @Test func twoFilesOfOneNameGetTheirOwnPlaces() throws {
        let folder = DownloadManager.handoffFolder
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("first".utf8).write(to: folder.appendingPathComponent("chart.torrent"))
        let second = DownloadManager.uniqueDestination(for: "chart.torrent", in: folder)
        #expect(second.lastPathComponent == "chart 2.torrent")
        #expect(second.deletingLastPathComponent() == folder)
    }

    /// What the folder is not: Downloads. A handoff's file must never be counted as one of the folders a finished
    /// download is looked for in, or a metafile would turn up in the browser's own download bookkeeping.
    @Test func theHandoffFolderIsNotWhereDownloadsGo() {
        #expect(DownloadManager.handoffFolder != DownloadManager.folder)
        #expect(!DownloadManager.folder.path.contains("/Handoffs"))
    }
}

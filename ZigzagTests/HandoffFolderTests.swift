import Foundation
import Testing
@testable import Zigzag

/// A File handoff's download waits in the system's temporary folder, not in Downloads (#589): it is a carrier for
/// the app or service, macOS clears that folder, and it is still there to be found if you want it — which is the
/// difference from deleting it after the handoff.
struct HandoffFolderTests {
    /// The folder exists after asking for it, it is the system's temporary folder, and only its owner may look in.
    @Test func theHandoffFolderIsInTheSystemTemporaryFolderAndPrivate() throws {
        let folder = DownloadManager.ensureHandoffFolder()
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
        let folder = DownloadManager.ensureHandoffFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = folder.appendingPathComponent("waiting.torrent")
        try Data("torrent".utf8).write(to: kept)
        #expect(DownloadManager.ensureHandoffFolder() == folder)
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    /// A name already taken in the handoff folder gets one of its own, as anywhere else: two handoffs of the same
    /// metafile name would otherwise be one file handed twice.
    @Test func twoFilesOfOneNameGetTheirOwnPlaces() throws {
        let folder = DownloadManager.ensureHandoffFolder()
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

    /// A handoff's file is a real download and says so: its row is marked temporary rather than the file being kept
    /// out of the list (#589). A file anywhere else — Downloads, a rule's own folder — is not marked.
    @Test func aHandoffFileIsMarkedTemporaryWhereverTheFolderIs() {
        let folder = DownloadManager.handoffFolder.standardizedFileURL.path
        func isTemporary(_ path: String) -> Bool {
            URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(folder + "/")
        }
        #expect(isTemporary(folder + "/chart.torrent"))
        #expect(!isTemporary("/Users/someone/Downloads/chart.torrent"))
        // A folder whose name merely starts the same way is not the handoff folder.
        #expect(!isTemporary(folder + "-2024/chart.torrent"))
    }

    /// The mark is read from the path, so it survives a relaunch with no new stored field: a list saved and read
    /// back knows a handoff's file is temporary, and one whose handoff folder has since been cleared is marked
    /// missing instead — which is the truth about it.
    @Test func theMarkIsReadFromWhereTheFileIs() {
        let folder = DownloadManager.handoffFolder.standardizedFileURL.path
        #expect(DownloadManager.handoffFolder.path.hasPrefix(FileManager.default.temporaryDirectory
            .appendingPathComponent("Handoffs").path))
        #expect(folder.hasSuffix("/Handoffs"))
        // A file beside the folder, whose name merely starts the same way, is not in it.
        let lookalike = DownloadManager.handoffFolder.deletingLastPathComponent()
            .appendingPathComponent("Handoffs-2024/chart.torrent")
        #expect(!lookalike.standardizedFileURL.path.hasPrefix(folder + "/"))
    }
}

import AppKit
import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A browser window with no window: enough of one for a page to start a download of its own.
@MainActor
private final class FolderTestHost: TabHost {
    var tabs: [Tab] = []
    var hostWindow: NSWindow? { nil }
    func tab(_ tab: Tab, openURL url: URL, disposition: OpenDisposition, by sender: Tab.LoadSender) {}
    func tab(_ tab: Tab, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
             features: WKWindowFeatures) -> WKWebView? { nil }
    func tabDidRequestClose(_ tab: Tab) {}
    func tabWantsToReturnToOpener(_ tab: Tab) {}
    func tab(_ tab: Tab, hoveringLink url: URL?) {}
    func tabWantsToBeShown(_ tab: Tab) {}
}

/// A download into a folder that isn't there, isn't a folder, or can't be written to says which folder and why, and
/// the folder picked in Settings is kept rather than quietly swapped for Downloads (#588).
struct DownloadFolderTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zz-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aFolderThereAndWritableHasNoProblem() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DownloadManager.folderProblem(dir) == nil)
    }

    @Test func aMissingFolderIsNamedAndSaysWhy() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Gone-\(UUID().uuidString)", isDirectory: true)
        let name = folder.lastPathComponent
        #expect(DownloadManager.folderProblem(folder) == "“\(name)” isn’t there. If it’s on another disk, that disk may not be mounted")
    }

    @Test func aFileWhereTheFolderShouldBeSaysSo() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Notes")
        try Data("x".utf8).write(to: file)
        #expect(DownloadManager.folderProblem(file) == "“Notes” isn’t a folder")
    }

    @Test func aReadOnlyFolderSaysItCantBeWrittenTo() throws {
        let dir = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(DownloadManager.folderProblem(dir) == "“\(dir.lastPathComponent)” can’t be written to")
    }

    /// The setup this was reported from: `~/Downloads` is a link to a folder on an external disk, and the disk is out.
    /// The link itself is there and its target is not, and `fileExists` follows the link, so it answers no — but the
    /// name that is said has to be Downloads, as the user knows it, never the link's target.
    @Test func aDownloadsLinkToAnUnmountedDiskIsNamed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("Downloads")
        let unmounted = URL(fileURLWithPath: "/Volumes/Unmounted-\(UUID().uuidString)/Downloads", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unmounted)
        #expect(DownloadManager.folderProblem(link) == "“Downloads” isn’t there. If it’s on another disk, that disk may not be mounted")
    }

    @Test func theChosenFolderIsKeptEvenWhenItIsGone() throws {
        let key = "DownloadFolder"
        let before = UserDefaults.standard.string(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("Gone-\(UUID().uuidString)", isDirectory: true)
        UserDefaults.standard.set(gone.path, forKey: key)
        #expect(DownloadManager.folder.standardizedFileURL == gone.standardizedFileURL)
        // Nothing picked: Downloads, as ever.
        UserDefaults.standard.removeObject(forKey: key)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        #expect(DownloadManager.folder.standardizedFileURL == downloads.standardizedFileURL)
    }

    /// A failed download says the folder's problem, which names the folder and why, rather than WebKit's "Couldn't
    /// save it in that folder"; a download into a folder that's fine keeps the error's own reason.
    @Test func theFolderIsNamedBeforeWebKitsOwnReason() {
        let missing = "“Downloads” isn’t there. If it’s on another disk, that disk may not be mounted"
        let webKit = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotCreateFile)
        #expect(DownloadManager.failure(webKit, placeProblem: missing) == missing)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(DownloadManager.failure(offline, placeProblem: nil) == "You’re offline")
    }

    /// What the downloads panel shows under the file's name when it fails: "Didn't finish." then the reason.
    @Test func theRowSaysTheFolderAndWhy() {
        let message = "“Movies” isn’t there. If it’s on another disk, that disk may not be mounted"
        #expect(DownloadRowView.failedStatus(message) == "Didn’t finish. “Movies” isn’t there. If it’s on another disk, that disk may not be mounted.")
        // No reason to give: just that it didn't finish, as before.
        #expect(DownloadRowView.failedStatus(nil) == "Didn’t finish")
    }

    /// A real download into a folder that's gone → a failed row that names the folder and why, with Try Again still
    /// offered (it will fail the same way until the disk is back, which is right), and nothing saved elsewhere.
    @MainActor @Test func aDownloadIntoAMissingFolderFailsAndSaysSo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Gone-\(UUID().uuidString)", isDirectory: true)
        let name = folder.lastPathComponent
        let keys = ["DownloadFolder", "DownloadsAskWhere"]
        let before = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in before { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        }
        DownloadManager.folder = folder
        DownloadManager.asksWhereToSave = false
        #expect(DownloadManager.folderProblem() == "“\(name)” isn’t there. If it’s on another disk, that disk may not be mounted")

        let server = try LocalPageServer { _, _ in
            LocalPageServer.Reply(headers: ["Content-Type": "application/octet-stream",
                                            "Content-Disposition": "attachment; filename=\"file.bin\""], body: Data("gone".utf8))
        }
        let site = try await server.start()
        defer { server.stop() }
        let host = FolderTestHost()
        let tab = Tab(url: nil, spaceID: UUID())
        tab.host = host
        host.tabs.append(tab)
        defer { host.tabs.forEach { $0.close() } }
        tab.load(site.appendingPathComponent("file.bin"))
        _ = tab.ensureWebView()

        // WebKit makes the download and fails to make the file: the row says what's actually wrong, not just "Didn't finish".
        var item: DownloadItem?
        for _ in 0..<300 {
            item = DownloadManager.shared.items(isPrivate: false).first { $0.destination?.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }
            if let item, item.state == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let failed = try #require(item)
        #expect(failed.state == .failed)
        #expect(failed.failure == "“\(name)” isn’t there. If it’s on another disk, that disk may not be mounted")
        #expect(DownloadRowView.failedStatus(failed.failure) == "Didn’t finish. “\(name)” isn’t there. If it’s on another disk, that disk may not be mounted.")
        // Try Again is still offered, since the file came from the web.
        #expect(DownloadManager.shared.canRetry(failed))
        // The folder is still gone: nothing was quietly made there, and nothing saved in Downloads instead.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        DownloadManager.shared.remove(failed)
    }
}

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Zigzag

/// Importing the extensions Firefox already downloaded: the scan reads each `.xpi`'s manifest where it lies, offers
/// the ones it finds, and installs one through the store's own path — the same package checks, the same record kind.
/// Every test points the scan at a profile root of its own, so no run opens the person's Firefox.
@MainActor
@Suite(.serialized)
struct FirefoxImportTests {
    /// A profile root and a store of their own: nothing read or written here lands in the person's Library.
    private final class Work {
        let folder: URL
        let root: URL
        let storeRoot: URL
        let profile: Profile

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-firefox-import-\(UUID().uuidString)")
            root = folder.appendingPathComponent("Profiles", isDirectory: true)
            storeRoot = folder.appendingPathComponent("Extensions", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
            profile = Profile(id: UUID())
            FirefoxImporter.rootOverride = root
            ExtensionStore.rootOverride = storeRoot
            ExtensionStore.forgetWhatWasRead()
        }

        /// A profile folder with its `extensions` folder, and the .xpi bytes given written into it.
        @discardableResult
        func profile(_ name: String, xpis: [(name: String, data: Data)]) throws -> URL {
            let profile = root.appendingPathComponent(name, isDirectory: true)
            let extensions = profile.appendingPathComponent("extensions", isDirectory: true)
            try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
            for xpi in xpis { try xpi.data.write(to: extensions.appendingPathComponent(xpi.name)) }
            return profile
        }

        func cleanUp() {
            FirefoxImporter.rootOverride = nil
            ExtensionStore.rootOverride = nil
            ExtensionStore.forgetWhatWasRead()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: profile.folder)
        }
    }

    private static func installed(_ result: Result<String, ExtensionStore.InstallError>) throws -> String {
        switch result {
        case .success(let name): return name
        case .failure(let error): throw error
        }
    }

    @Test func aProfileWithAnXPIIsFoundWithItsNameVersionAndGeckoID() throws {
        let work = try Work()
        defer { work.cleanUp() }
        let xpi = try XPIArchive.xpi(XPIArchive.manifest("a@b", "1.2.3", ["name": "Test Extension"]))
        try work.profile("abc.default", xpis: [("a@b.xpi", xpi)])

        let found = FirefoxImporter.found(in: work.root)
        #expect(found.count == 1)
        let one = try #require(found.first)
        #expect(one.name == "Test Extension")
        #expect(one.version == "1.2.3")
        #expect(one.firefoxID == "a@b")
        #expect(one.path.lastPathComponent == "a@b.xpi")
        #expect(one.source == "abc.default")
    }

    /// Only `.xpi` files in a profile's `extensions` folder count. A file of another kind, a folder, and a package
    /// whose zip is damaged are all left out — the damaged one is skipped, not thrown, so the scan never stops.
    @Test func filesThatAreNotXPIsAreIgnoredAndAMalformedXPIIsSkipped() throws {
        let work = try Work()
        defer { work.cleanUp() }
        let profile = try work.profile("abc.default", xpis: [
            ("good.xpi", try XPIArchive.xpi(XPIArchive.manifest("good@example.com", "1.0"))),
            ("broken.xpi", Data("this is not a zip at all".utf8)),
            ("notes.txt", Data("just a note".utf8)),
        ])
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("extensions/loose.xpi", isDirectory: true),
                                                withIntermediateDirectories: true)

        // Reading one profile alone skips the broken one without throwing.
        let one = FirefoxImporter.found(inProfile: profile)
        #expect(one.map(\.firefoxID) == ["good@example.com"])
        // And the whole scan is unaffected by it.
        let found = FirefoxImporter.found(in: work.root)
        #expect(found.map(\.name) == ["Test"])
        #expect(found.map(\.firefoxID) == ["good@example.com"])
    }

    /// The same gecko ID is the same extension, however many profiles hold it: one entry, and the one from the first
    /// profile by name wins.
    @Test func twoProfilesWithTheSameGeckoIDGiveOneEntryAndTheFirstProfileWins() throws {
        let work = try Work()
        defer { work.cleanUp() }
        try work.profile("b.work", xpis: [("same.xpi", try XPIArchive.xpi(XPIArchive.manifest("same@example.com", "1.0", ["name": "From B"])))])
        try work.profile("a.personal", xpis: [("same.xpi", try XPIArchive.xpi(XPIArchive.manifest("same@example.com", "2.0", ["name": "From A"])))])

        let found = FirefoxImporter.found(in: work.root)
        #expect(found.count == 1)
        #expect(found.first?.source == "a.personal")
        #expect(found.first?.name == "From A")
        #expect(found.first?.version == "2.0")
    }

    /// The import row's own path, without the review sheet it puts up first: `ImportView.addFirefox` prepares the
    /// package and, once the sheet is confirmed (`ExtensionSheet.offer`), finishes the install. The record it leaves
    /// says Firefox with its gecko ID. The sheet itself is UI, so it is left out here.
    @Test func theImportRowsPreparedInstallRecordsFirefox() async throws {
        let work = try Work()
        defer { work.cleanUp() }
        try work.profile("abc.default", xpis: [("one.xpi", try XPIArchive.xpi(XPIArchive.manifest("one@example.com", "1.0")))])

        let found = try #require(FirefoxImporter.found(in: work.root).first)
        guard case .success(let prepared) = await ExtensionStore.prepareInstallXPI(at: found.path) else {
            Issue.record("expected a prepared install")
            return
        }
        let name = try Self.installed(await ExtensionStore.finishInstall(prepared, in: work.profile))
        #expect(name == "Test")

        let id = ExtensionStore.xpiID(forGeckoID: "one@example.com", data: Data())
        let record = try #require(ExtensionStore.package(id))
        #expect(record.kind == "firefox")
        #expect(record.firefoxID == "one@example.com")
    }

    /// The extension file picker offers a folder and a Firefox package (.xpi). A Chrome package (.crx) is not offered:
    /// no .crx install path exists here, so a picked one had no way in.
    @Test func theExtensionFilePickerAllowsXPIAsWellAsFolders() {
        let types = ExtensionFilePicker.types
        #expect(types.contains(.folder))
        let extensions = types.compactMap(\.preferredFilenameExtension)
        #expect(extensions.contains("xpi"))
        #expect(!extensions.contains("crx"))
    }

    /// A Firefox package's row in Settings › Extensions says it is one, and no more: its gecko ID is Firefox's name
    /// for it, not something to read at a glance. A Chrome package's row says neither.
    @Test func aFirefoxRowSaysFirefoxAndAChromeRowSaysNothing() throws {
        let work = try Work()
        defer { work.cleanUp() }
        let firefox = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let chrome = "abcdefghijklmnopabcdefghijklmnop"
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", kind: "firefox", firefoxID: "one@example.com"), for: firefox)
        ExtensionStore.save(ExtensionStore.Package(version: "1.0"), for: chrome)

        #expect(SettingsView.packageKindDetail(firefox) == ["Firefox"])
        #expect(SettingsView.packageKindDetail(chrome).isEmpty)
    }

    /// The note under the choices tells the truth in every reachable state: it points at the Firefox rows only when
    /// they are showing, and simply says where Firefox's extensions come from when none are. It is there at all only
    /// with Firefox or Safari in the choice (Safari, or Firefox before its rows arrive).
    @Test func theChoicesNotePointsAtFirefoxRowsOnlyWhenTheyAreShowing() {
        let noRows = ImportView.choicesNote(signIns: false, otherStores: true, firefoxListed: false)
        #expect(noRows.contains("Chrome Web Store"))
        #expect(!noRows.contains("listed above"))

        let rows = ImportView.choicesNote(signIns: false, otherStores: true, firefoxListed: true)
        #expect(rows.contains("Chrome Web Store"))
        #expect(rows.contains("listed above"))
        #expect(rows != noRows)

        // With no Firefox or Safari in the choice, there is no line to show, rows or not.
        #expect(ImportView.choicesNote(signIns: false, otherStores: false, firefoxListed: false).isEmpty)
        #expect(ImportView.choicesNote(signIns: false, otherStores: false, firefoxListed: true).isEmpty)

        // Sign-ins keeps its sentence, either way.
        let both = ImportView.choicesNote(signIns: true, otherStores: true, firefoxListed: false)
        #expect(both.contains("Sign-ins") && both.contains("Chrome Web Store"))
    }
}

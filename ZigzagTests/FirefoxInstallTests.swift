import Foundation
import Testing
@testable import Zigzag

/// An XPI made byte by byte: stored entries, then the central index and its end record. Shared by every test that
/// needs one — `FirefoxInstallTests`, `FirefoxImportTests`, `FirefoxCompatibilityTests` and `XPIPackageTests` — so
/// there is one zip writer, not a copy per file. The local gate compiles the requested suites together (and CI
/// compiles the whole target), so a declaration here reaches the other suites.
///
/// Kept in this file rather than a file of its own: the local gate copies only the files that declare a suite it was
/// asked for, so a standalone fixture file would not be compiled. (Reported to the reviewer.)
nonisolated struct XPIArchive {
    struct Entry {
        var name: String
        var data = Data()
        var mode: UInt32 = 0o100644
    }

    var entries: [Entry]

    var data: Data {
        var archive = Data(), index = Data()
        func u16(_ value: UInt16, into bytes: inout Data) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32, into bytes: inout Data) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        for entry in entries {
            let name = Data(entry.name.utf8), crc = PackageZip.crc32([UInt8](entry.data)), offset = UInt32(archive.count)
            u32(0x0403_4B50, into: &archive); u16(20, into: &archive); u16(0, into: &archive); u16(0, into: &archive)
            u16(0, into: &archive); u16(0, into: &archive); u32(crc, into: &archive)
            u32(UInt32(entry.data.count), into: &archive); u32(UInt32(entry.data.count), into: &archive)
            u16(UInt16(name.count), into: &archive); u16(0, into: &archive); archive.append(name); archive.append(entry.data)
            u32(0x0201_4B50, into: &index); u16(0x0314, into: &index); u16(20, into: &index); u16(0, into: &index)
            u16(0, into: &index); u16(0, into: &index); u16(0, into: &index); u32(crc, into: &index)
            u32(UInt32(entry.data.count), into: &index); u32(UInt32(entry.data.count), into: &index)
            u16(UInt16(name.count), into: &index); u16(0, into: &index); u16(0, into: &index)
            u16(0, into: &index); u16(0, into: &index); u32(entry.mode << 16, into: &index); u32(offset, into: &index)
            index.append(name)
        }
        let start = UInt32(archive.count)
        archive.append(index)
        u32(0x0605_4B50, into: &archive); u16(0, into: &archive); u16(0, into: &archive)
        u16(UInt16(entries.count), into: &archive); u16(UInt16(entries.count), into: &archive)
        u32(UInt32(index.count), into: &archive); u32(start, into: &archive); u16(0, into: &archive)
        return archive
    }

    static func json(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    /// An XPI whose root manifest is `manifest`, with any of its files beside it.
    static func xpi(_ manifest: [String: Any], files: [String: Data] = [:]) throws -> Data {
        var entries = [Entry(name: "manifest.json", data: try json(manifest))]
        for (name, data) in files.sorted(by: { $0.key < $1.key }) { entries.append(.init(name: name, data: data)) }
        return XPIArchive(entries: entries).data
    }

    /// An XPI whose manifest is the bytes given: for a manifest WebKit can't read, whatever JSON sees in it.
    static func xpi(manifestData: Data) -> Data {
        XPIArchive(entries: [.init(name: "manifest.json", data: manifestData)]).data
    }

    /// A Firefox manifest, with whatever else the test needs.
    static func manifest(_ geckoID: String?, _ version: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = ["manifest_version": 2, "name": "Test", "version": version]
        if let geckoID { fields["browser_specific_settings"] = ["gecko": ["id": geckoID]] }
        for (key, value) in extra { fields[key] = value }
        return fields
    }
}

/// Installing a Firefox package (.xpi): it gets a record of its own — its kind, its gecko ID and the opaque ID it
/// installs as — the package is unpacked as a Chrome one is, and its manifest is made into the shape WebKit loads
/// before anything is handed over.
@MainActor
@Suite(.serialized)
struct FirefoxInstallTests {
    // MARK: The store the tests work in

    /// A store of its own: the packages go in a temporary folder and the profile is one no list knows, so nothing
    /// an install writes lands in the person's own Extensions folder or Library.
    private final class Workspace {
        let folder: URL
        let root: URL
        let profile: Profile

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-firefox-install-\(UUID().uuidString)")
            root = folder.appendingPathComponent("Extensions", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            profile = Profile(id: UUID())
            ExtensionStore.rootOverride = root
            ExtensionStore.forgetWhatWasRead()
        }

        /// An .xpi written where the test can hand it to the store.
        func xpiFile(_ data: Data) throws -> URL {
            let url = folder.appendingPathComponent("\(UUID().uuidString).xpi")
            try data.write(to: url)
            return url
        }

        func record(_ id: String) -> ExtensionStore.Package? { ExtensionStore.package(id) }

        func cleanUp() {
            ExtensionStore.rootOverride = nil
            ExtensionStore.forgetWhatWasRead()
            try? FileManager.default.removeItem(at: folder)
            // The profile isn't one any list knows: its own folder is this test's, and goes with it.
            try? FileManager.default.removeItem(at: profile.folder)
        }
    }

    // MARK: Fixtures

    private static func xpi(_ manifest: [String: Any], files: [String: Data] = [:]) throws -> Data {
        try XPIArchive.xpi(manifest, files: files)
    }

    private static func xpi(manifestData: Data) -> Data { XPIArchive.xpi(manifestData: manifestData) }

    private static func manifest(_ geckoID: String?, _ version: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        XPIArchive.manifest(geckoID, version, extra)
    }

    private static func installed(_ result: Result<String, ExtensionStore.InstallError>) throws -> String {
        switch result {
        case .success(let name): return name
        case .failure(let error): throw error
        }
    }

    /// Installs an `.xpi` through the store's own two steps, as every caller does: prepare, then finish once the
    /// review sheet is confirmed (`ExtensionSheet.offer` in the app). A test convenience, so the store keeps one
    /// install path and none of its own installs past the sheet.
    private static func install(at url: URL, in profile: Profile) async -> Result<String, ExtensionStore.InstallError> {
        switch await ExtensionStore.prepareInstallXPI(at: url) {
        case .success(let prepared): return await ExtensionStore.finishInstall(prepared, in: profile)
        case .failure(let error): return .failure(error)
        }
    }

    /// The staging folders an install makes while it works: none should outlive the call.
    private static func stagingFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("zigzag-xpi-") })
    }

    // MARK: Tests

    @Test func installingAnXPIRecordsItsKindGeckoIDAndOpaqueID() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("one@example.com", "1.2.3")))
        let name = try Self.installed(await Self.install(at: url, in: work.profile))
        #expect(name == "Test")

        let id = ExtensionStore.xpiID(forGeckoID: "one@example.com", data: Data())
        // Chrome's own alphabet, the shape the rest of the store assumes.
        #expect(id.count == 32)
        #expect(id.allSatisfy { ("a"..."p").contains($0) })
        #expect(ExtensionStore.isExtensionID(id))
        let record = try #require(work.record(id))
        #expect(record.kind == "firefox")
        #expect(record.firefoxID == "one@example.com")
        #expect(record.version == "1.2.3")
        #expect(try #require(work.profile.installs.state(id)).enabled)
    }

    @Test func twoXPIsWithTheSameGeckoIDAreOneRecordAndTheVersionIsReplaced() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        _ = try Self.installed(await Self.install(at: try work.xpiFile(try Self.xpi(Self.manifest("same@example.com", "1.0"))), in: work.profile))
        _ = try Self.installed(await Self.install(at: try work.xpiFile(try Self.xpi(Self.manifest("same@example.com", "2.0"))), in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "same@example.com", data: Data())
        #expect(ExtensionStore.packageIDs == [id])
        #expect(work.record(id)?.version == "2.0")
        let versions = try FileManager.default.contentsOfDirectory(atPath: work.root.appendingPathComponent(id).appendingPathComponent("versions").path)
        #expect(versions == ["2.0"])
    }

    @Test func aRecordWrittenWithoutAKindReadsAsChromium() throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let folder = work.root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":"9.9","unpackedPath":"/somewhere/else"}"#.utf8).write(to: folder.appendingPathComponent("state.json"))
        let record = try #require(work.record(id))
        #expect(record.kind == "chromium")
        #expect(record.firefoxID == nil)
        #expect(record.version == "9.9")
        #expect(record.unpackedPath == "/somewhere/else")

        // A Firefox record keeps both its own way.
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", kind: "firefox", firefoxID: "a@b"), for: id)
        let saved = try #require(work.record(id))
        #expect(saved.kind == "firefox" && saved.firefoxID == "a@b")
    }

    /// An MV3 Firefox manifest keeps host patterns in `permissions` and its policy as one string: exactly what
    /// normalization exists to rescue. It installs, and the copy on disk is the normalized one.
    @Test func anMV3XPIWithHostsInPermissionsAndAStringPolicyInstallsNormalized() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("hosts@example.com", "2.0", [
            "manifest_version": 3,
            "permissions": ["storage", "https://example.com/*"],
            "optional_permissions": ["*://*.other.test/*"],
            "content_security_policy": "script-src 'self'; object-src 'self'",
        ])))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "hosts@example.com", data: Data())
        let folder = try #require(ExtensionStore.packageDirectory(for: id))
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        // The host patterns moved where WebKit reads site access; the API permission stayed where it was.
        #expect(onDisk["permissions"] as? [String] == ["storage"])
        #expect(onDisk["host_permissions"] as? [String] == ["https://example.com/*"])
        #expect(onDisk["optional_permissions"] as? [String] == [])
        #expect(onDisk["optional_host_permissions"] as? [String] == ["*://*.other.test/*"])
        // Firefox's one-string policy became the shape WebKit expects.
        let policy = try #require(onDisk["content_security_policy"] as? [String: Any])
        #expect(policy["extension_pages"] as? String == "script-src 'self'; object-src 'self'")
    }

    /// A package's own manifest can be one WebKit can't read as it came (not UTF-8); the normalized copy we write is
    /// what WebKit loads, so it installs. Verifying before normalization would have refused it.
    @Test func aManifestWebKitCannotReadAsItCameIsRescuedByNormalization() async throws {
        let manifestData = try #require(#"{"manifest_version":2,"name":"Rescued","version":"1.0","browser_specific_settings":{"gecko":{"id":"rescued@example.com"}}}"#.data(using: .utf16LittleEndian))
        let xpi = Self.xpi(manifestData: manifestData)
        // The package itself is sound: its manifest is JSON, just not in an encoding WebKit reads.
        #expect(try XPIPackage(xpi).manifest["name"] as? String == "Rescued")
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(xpi)
        let name = try Self.installed(await Self.install(at: url, in: work.profile))
        #expect(name == "Rescued")
        let id = ExtensionStore.xpiID(forGeckoID: "rescued@example.com", data: Data())
        #expect(work.record(id)?.kind == "firefox")
    }

    /// A manifest version WebKit doesn't run: its parser takes the manifest, but nothing here implements it, so the
    /// package is refused and nothing is left staged.
    @Test func anXPIWhoseManifestWebKitCannotRunFailsUnsupportedAndLeavesNoStaging() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("future@example.com", "1.0", ["manifest_version": 5])))

        let before = Self.stagingFolders()
        let result = await ExtensionStore.prepareInstallXPI(at: url)
        guard case .failure(let error) = result, case .unsupported = error else {
            Issue.record("expected .unsupported, got \(result)")
            return
        }
        #expect(Self.stagingFolders() == before)
    }

    /// Firefox versions may carry letters (`1.0.0b1`), which Chrome's grammar refuses. A package isn't damaged over
    /// one: it installs, and the version it declares is the one recorded.
    @Test func aFirefoxVersionWithLettersInstallsAndIsRecorded() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("letters@example.com", "1.0.0b1")))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "letters@example.com", data: Data())
        #expect(work.record(id)?.version == "1.0.0b1")
        let versions = try FileManager.default.contentsOfDirectory(atPath: work.root.appendingPathComponent(id).appendingPathComponent("versions").path)
        #expect(versions == ["1.0.0b1"])
    }

    /// A Firefox version names the folder it's kept in, so it still has to be a safe name: no separators, no
    /// climbing out, not empty, not enormous.
    @Test func aFirefoxVersionMustStillBeASafeFolderName() {
        for good in ["1.0", "1.0.0b1", "2024.1-beta", "3.0.0.0", "1.2.3+build"] {
            #expect(ExtensionStore.isValidFirefoxVersion(good), "\(good)")
        }
        for bad in ["", ".", "..", "a/b", "a\\b", "a..b", ".hidden", "a b", String(repeating: "1", count: 65)] {
            #expect(!ExtensionStore.isValidFirefoxVersion(bad), "\(bad)")
        }
    }

    @Test func anMV3ModuleBackgroundGetsAnImportingWorkerOnDisk() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let background: [String: Any] = ["scripts": ["a.js", "b.js"], "type": "module"]
        let url = try work.xpiFile(try Self.xpi(Self.manifest("module@example.com", "3.0", [
            "manifest_version": 3, "background": background,
        ]), files: ["a.js": Data("let a = 1;".utf8), "b.js": Data("let b = 2;".utf8)]))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "module@example.com", data: Data())
        let folder = try #require(ExtensionStore.packageDirectory(for: id))
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let written = try #require(onDisk["background"] as? [String: Any])
        #expect(written["service_worker"] as? String == FirefoxManifest.workerFile)
        // A module worker can't run importScripts; it imports each script in order.
        #expect(written["type"] as? String == "module")
        let worker = try String(contentsOf: folder.appendingPathComponent(FirefoxManifest.workerFile), encoding: .utf8)
        #expect(worker == "import \"./a.js\";\nimport \"./b.js\";\n")
    }

    @Test func anMV3ClassicBackgroundGetsImportScripts() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("classic@example.com", "3.0", [
            "manifest_version": 3, "background": ["scripts": ["a.js"]],
        ]), files: ["a.js": Data("let a = 1;".utf8)]))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "classic@example.com", data: Data())
        let folder = try #require(ExtensionStore.packageDirectory(for: id))
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let written = try #require(onDisk["background"] as? [String: Any])
        #expect(written["service_worker"] as? String == FirefoxManifest.workerFile)
        #expect(written["type"] == nil)
        let worker = try String(contentsOf: folder.appendingPathComponent(FirefoxManifest.workerFile), encoding: .utf8)
        #expect(worker == "importScripts(\"a.js\");")
    }

    @Test func aPreparedXPIReportsItsKindAndID() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("prepared@example.com", "1.0")))
        let result = await ExtensionStore.prepareInstallXPI(at: url)
        guard case .success(let prepared) = result else {
            Issue.record("expected a prepared install, got \(result)")
            return
        }
        defer { ExtensionStore.discard(prepared) }
        #expect(prepared.kind == .firefox)
        #expect(prepared.firefoxID == "prepared@example.com")
        #expect(ExtensionStore.isExtensionID(prepared.id))
        #expect(prepared.version == "1.0")
    }

    /// A Chrome package's prepared install is a Chrome one, as every caller before this task already assumed.
    @Test func aChromeRecordStillReadsAsChromium() throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let id = "abcdefghijklmnopabcdefghijklmnop"
        ExtensionStore.save(ExtensionStore.Package(version: "1.0"), for: id)
        #expect(work.record(id)?.kind == "chromium")
        #expect(work.record(id)?.firefoxID == nil)
    }

    /// Only the store's own packages are asked about updates: a Firefox package came from a file, and an unpacked one
    /// is the person's folder. Asking Google for either would be a request it can't answer.
    @Test func onlyTheStoresOwnPackagesAreAskedForUpdates() throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let chrome = "abcdefghijklmnopabcdefghijklmnop"
        let firefox = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let unpacked = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ExtensionStore.save(ExtensionStore.Package(version: "1.0"), for: chrome)
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", kind: "firefox", firefoxID: "one@example.com"), for: firefox)
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", unpackedPath: work.folder.path), for: unpacked)

        #expect(ExtensionStore.updateCandidates([chrome, firefox, unpacked]) == [chrome])
    }

    /// No gecko ID: the package is named by its bytes, so the same file at two paths is one record.
    @Test func anXPIWithNoGeckoIDIsNamedByItsBytesSoTheSameFileAtTwoPathsIsOneRecord() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let bytes = try Self.xpi(Self.manifest(nil, "1.0"))
        _ = try Self.installed(await Self.install(at: try work.xpiFile(bytes), in: work.profile))
        _ = try Self.installed(await Self.install(at: try work.xpiFile(bytes), in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: nil, data: bytes)
        #expect(ExtensionStore.packageIDs == [id])
        #expect(work.record(id)?.firefoxID == nil)
        #expect(SettingsView.packageKindDetail(id) == ["Firefox"])
    }

    /// A signature file in the package changes nothing Zigzag says: its presence isn't a check that the signature is
    /// valid, so Settings says only that this is a Firefox extension, and records the package the same way.
    @Test func aSignatureFileChangesNothingZigzagSays() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let bytes = XPIArchive(entries: [
            .init(name: "manifest.json", data: try XPIArchive.json(Self.manifest("signed@example.com", "1.0"))),
            .init(name: "META-INF/mozilla.rsa", data: Data("signature".utf8)),
        ]).data
        _ = try Self.installed(await Self.install(at: try work.xpiFile(bytes), in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "signed@example.com", data: Data())
        #expect(work.record(id)?.kind == "firefox")
        #expect(SettingsView.packageKindDetail(id) == ["Firefox"])
    }

    /// The manifest Zigzag stores is the normalized copy, and it still carries the keys firefox-polyfill.js gates on:
    /// a key-pruning step that dropped them would silently darken every Firefox extension.
    @Test func theInstalledManifestKeepsTheKeysThePolyfillGatesOn() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("keys@example.com", "1.0", ["background": ["scripts": ["a.js"]]])))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "keys@example.com", data: Data())
        let folder = try #require(ExtensionStore.packageDirectory(for: id))
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(FirefoxManifest.isFirefox(onDisk))
        #expect((onDisk["browser_specific_settings"] as? [String: Any])?["gecko"] != nil)
    }

    /// A folder installed from disk that carries Firefox's own keys is recorded as Firefox with its gecko ID, so its
    /// record, its sheet and its polyfill agree — and the person's own folder is left exactly as it is, never
    /// normalized. A folder without those keys stays Chrome's.
    @Test func aFirefoxFolderIsRecordedFirefoxWithItsGeckoIDAndLeftAsItIs() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let folder = work.folder.appendingPathComponent("firefox-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = Self.manifest("folder@example.com", "1.0", ["permissions": ["contextualIdentities"]])
        manifest["sidebar_action"] = ["default_panel": "panel.html"]
        try XPIArchive.json(manifest).write(to: folder.appendingPathComponent("manifest.json"))

        let record = ExtensionStore.unpackedPackage(for: folder)
        #expect(record.kind == "firefox")
        #expect(record.firefoxID == "folder@example.com")
        #expect(record.unpackedPath == folder.standardizedFileURL.path)
        // The sheet reads Firefox's overlay for it, as its record says.
        let reviewed = try #require(await ExtensionStore.reviewUnpacked(folder))
        #expect(reviewed.report.limits.map(\.text).contains("Containers"))
        // Nothing was written back: no normalized side_panel twin in the person's own folder.
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(onDisk["side_panel"] == nil)

        let chromeFolder = work.folder.appendingPathComponent("chrome-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: chromeFolder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":2,"name":"Chrome","version":"1.0"}"#.utf8).write(to: chromeFolder.appendingPathComponent("manifest.json"))
        let chrome = ExtensionStore.unpackedPackage(for: chromeFolder)
        #expect(chrome.kind == "chromium")
        #expect(chrome.firefoxID == nil)
    }
}

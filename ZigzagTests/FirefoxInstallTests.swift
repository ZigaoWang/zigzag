import Foundation
import Testing
@testable import Zigzag

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

    /// An XPI made byte by byte: stored entries, then the central index and its end record.
    private struct TestXPI {
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
    }

    private static func json(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    /// An XPI whose root manifest is `manifest`, with any of its files beside it.
    private static func xpi(_ manifest: [String: Any], files: [String: Data] = [:]) throws -> Data {
        var entries = [TestXPI.Entry(name: "manifest.json", data: try json(manifest))]
        for (name, data) in files.sorted(by: { $0.key < $1.key }) { entries.append(.init(name: name, data: data)) }
        return TestXPI(entries: entries).data
    }

    /// An XPI whose manifest is the bytes given: for a manifest WebKit can't read, whatever JSON sees in it.
    private static func xpi(manifestData: Data) -> Data {
        TestXPI(entries: [.init(name: "manifest.json", data: manifestData)]).data
    }

    /// A Firefox manifest, with whatever else the test needs.
    private static func manifest(_ geckoID: String?, _ version: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = ["manifest_version": 2, "name": "Test", "version": version]
        if let geckoID { fields["browser_specific_settings"] = ["gecko": ["id": geckoID]] }
        for (key, value) in extra { fields[key] = value }
        return fields
    }

    private static func installed(_ result: Result<String, ExtensionStore.InstallError>) throws -> String {
        switch result {
        case .success(let name): return name
        case .failure(let error): throw error
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
        let name = try Self.installed(await ExtensionStore.installXPI(at: url, in: work.profile))
        #expect(name == "Test")

        let id = ExtensionStore.xpiID(forGeckoID: "one@example.com", at: url)
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
        _ = try Self.installed(await ExtensionStore.installXPI(at: try work.xpiFile(try Self.xpi(Self.manifest("same@example.com", "1.0"))), in: work.profile))
        _ = try Self.installed(await ExtensionStore.installXPI(at: try work.xpiFile(try Self.xpi(Self.manifest("same@example.com", "2.0"))), in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "same@example.com", at: work.root)
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

    @Test func anXPIWebKitCannotReadFailsUnsupportedAndLeavesNoStaging() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        // A manifest JSONSerialization reads (so the package itself is sound) but WebKit's parser can't: it isn't
        // UTF-8, and has no byte order mark to say so.
        let manifestData = try #require(#"{"manifest_version":3,"name":"Broken","version":"1.0"}"#.data(using: .utf16LittleEndian))
        let xpi = Self.xpi(manifestData: manifestData)
        #expect(try XPIPackage(xpi).manifest["name"] as? String == "Broken")
        let url = try work.xpiFile(xpi)

        let before = Self.stagingFolders()
        let result = await ExtensionStore.prepareInstallXPI(at: url)
        guard case .failure(let error) = result, case .unsupported = error else {
            Issue.record("expected .unsupported, got \(result)")
            return
        }
        #expect(Self.stagingFolders() == before)
    }

    @Test func anMV3ModuleBackgroundGetsAnImportingWorkerOnDisk() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let background: [String: Any] = ["scripts": ["a.js", "b.js"], "type": "module"]
        let url = try work.xpiFile(try Self.xpi(Self.manifest("module@example.com", "3.0", [
            "manifest_version": 3, "background": background,
        ]), files: ["a.js": Data("let a = 1;".utf8), "b.js": Data("let b = 2;".utf8)]))
        _ = try Self.installed(await ExtensionStore.installXPI(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "module@example.com", at: url)
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
        _ = try Self.installed(await ExtensionStore.installXPI(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "classic@example.com", at: url)
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
}

import Foundation
import Testing
@testable import Zigzag

/// An XPI made byte by byte: stored entries, then the central index and its end record.
private struct TestXPI {
    var entries: [(name: String, data: Data)]

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
            u16(0, into: &index); u16(0, into: &index); u32(0o100644 << 16, into: &index); u32(offset, into: &index)
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

/// What an XPI is before it is a folder: its manifest at the root, the gecko ID it installs as, and whether Mozilla
/// signed it. The entries are checked as a Chrome package's are, so nothing lands outside the folder.
struct XPIPackageTests {
    private static let manifest: [String: Any] = ["manifest_version": 2, "name": "Test", "version": "1.0"]

    private static func json(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    @Test func readsTheManifestAtTheRoot() throws {
        let package = try XPIPackage(TestXPI(entries: [("manifest.json", try Self.json(Self.manifest))]).data)
        #expect(package.manifest["name"] as? String == "Test")
        #expect(package.manifest["version"] as? String == "1.0")
        #expect(package.firefoxID == nil)
        #expect(!package.hasSignature)
    }

    @Test func readsTheGeckoID() throws {
        var fields = Self.manifest
        fields["browser_specific_settings"] = ["gecko": ["id": "test@example.com"]]
        let package = try XPIPackage(TestXPI(entries: [("manifest.json", try Self.json(fields))]).data)
        #expect(package.firefoxID == "test@example.com")
    }

    @Test func readsTheLegacyApplicationsGeckoID() throws {
        var fields = Self.manifest
        fields["applications"] = ["gecko": ["id": "legacy@example.com"]]
        let package = try XPIPackage(TestXPI(entries: [("manifest.json", try Self.json(fields))]).data)
        #expect(package.firefoxID == "legacy@example.com")

        // Both spellings: the current one is what the extension installs as.
        fields["browser_specific_settings"] = ["gecko": ["id": "current@example.com"]]
        let both = try XPIPackage(TestXPI(entries: [("manifest.json", try Self.json(fields))]).data)
        #expect(both.firefoxID == "current@example.com")
    }

    @Test func marksASignedPackage() throws {
        let package = try XPIPackage(TestXPI(entries: [
            ("manifest.json", try Self.json(Self.manifest)),
            ("META-INF/mozilla.rsa", Data("signature".utf8)),
        ]).data)
        #expect(package.hasSignature)
    }

    @Test func refusesAPackageWithoutAManifest() throws {
        let data = TestXPI(entries: [("background.js", Data("let a = 1;".utf8))]).data
        #expect(throws: XPIPackage.Failure.missingManifest) { try XPIPackage(data) }
    }

    @Test func refusesAManifestThatIsNotAtTheRoot() throws {
        let data = TestXPI(entries: [("extension/manifest.json", try Self.json(Self.manifest))]).data
        #expect(throws: XPIPackage.Failure.manifestNotAtRoot) { try XPIPackage(data) }
    }

    @Test func refusesAManifestThatIsNotJSON() {
        let data = TestXPI(entries: [("manifest.json", Data("not json".utf8))]).data
        #expect(throws: XPIPackage.Failure.damaged) { try XPIPackage(data) }
    }

    @Test func refusesAnEntryThatReachesOutside() throws {
        let data = TestXPI(entries: [("manifest.json", try Self.json(Self.manifest)), ("../escaped.txt", Data("x".utf8))]).data
        #expect(throws: XPIPackage.Failure.unsafeName("../escaped.txt")) { try XPIPackage(data) }
    }

    @Test func unpacksItsFilesIntoANewFolder() throws {
        let manifestData = try Self.json(Self.manifest)
        let package = try XPIPackage(TestXPI(entries: [
            ("manifest.json", manifestData),
            ("js/background.js", Data("let a = 1;".utf8)),
        ]).data)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("XPIPackageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try package.unpack(into: folder)
        #expect(try Data(contentsOf: folder.appendingPathComponent("manifest.json")) == manifestData)
        #expect(try String(contentsOf: folder.appendingPathComponent("js/background.js"), encoding: .utf8) == "let a = 1;")
    }
}

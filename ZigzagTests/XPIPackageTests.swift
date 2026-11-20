import Foundation
import Testing
@testable import Zigzag

/// What an XPI is before it is a folder: its manifest at the root, the gecko ID it installs as, and whether Mozilla
/// signed it. The entries are checked as a Chrome package's are, so nothing lands outside the folder. The zip fixture
/// is the shared `XPIArchive`, declared beside `FirefoxInstallTests`.
struct XPIPackageTests {
    private static let manifest: [String: Any] = ["manifest_version": 2, "name": "Test", "version": "1.0"]

    private static func json(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    @Test func readsTheManifestAtTheRoot() throws {
        let package = try XPIPackage(XPIArchive(entries: [.init(name: "manifest.json", data: try Self.json(Self.manifest))]).data)
        #expect(package.manifest["name"] as? String == "Test")
        #expect(package.manifest["version"] as? String == "1.0")
        #expect(package.firefoxID == nil)
    }

    @Test func readsTheGeckoID() throws {
        var fields = Self.manifest
        fields["browser_specific_settings"] = ["gecko": ["id": "test@example.com"]]
        let package = try XPIPackage(XPIArchive(entries: [.init(name: "manifest.json", data: try Self.json(fields))]).data)
        #expect(package.firefoxID == "test@example.com")
    }

    @Test func readsTheLegacyApplicationsGeckoID() throws {
        var fields = Self.manifest
        fields["applications"] = ["gecko": ["id": "legacy@example.com"]]
        let package = try XPIPackage(XPIArchive(entries: [.init(name: "manifest.json", data: try Self.json(fields))]).data)
        #expect(package.firefoxID == "legacy@example.com")

        // Both spellings: the current one is what the extension installs as.
        fields["browser_specific_settings"] = ["gecko": ["id": "current@example.com"]]
        let both = try XPIPackage(XPIArchive(entries: [.init(name: "manifest.json", data: try Self.json(fields))]).data)
        #expect(both.firefoxID == "current@example.com")
    }

    /// A gecko ID is only read where it is a string; anything else is a manifest with none.
    @Test func ignoresAGeckoIDItCannotRead() throws {
        let shapes: [[String: Any]] = [
            ["browser_specific_settings": ["gecko": "test@example.com"]],
            ["browser_specific_settings": ["gecko": ["id": 42]]],
            ["applications": ["gecko": []]],
            ["browser_specific_settings": []],
        ]
        for shape in shapes {
            var fields = Self.manifest
            for (key, value) in shape { fields[key] = value }
            let package = try XPIPackage(XPIArchive(entries: [.init(name: "manifest.json", data: try Self.json(fields))]).data)
            #expect(package.firefoxID == nil)
        }
    }

    /// A signature file Mozilla added is left alone, and never read as a signature Zigzag stood behind: the package
    /// is still read by its manifest, as one without it is.
    @Test func aSignatureFileInThePackageIsNotReadAsOne() throws {
        let package = try XPIPackage(XPIArchive(entries: [
            .init(name: "manifest.json", data: try Self.json(Self.manifest)),
            .init(name: "META-INF/mozilla.rsa", data: Data("signature".utf8)),
        ]).data)
        #expect(package.manifest["name"] as? String == "Test")
        #expect(package.firefoxID == nil)
    }

    /// An empty object is a manifest with nothing in it, not a damaged package.
    @Test func readsAnEmptyManifest() throws {
        let package = try XPIPackage(XPIArchive(entries: [.init(name: "manifest.json", data: Data("{}".utf8))]).data)
        #expect(package.manifest.isEmpty)
        #expect(package.firefoxID == nil)
    }

    /// JSON that is not an object at all is not a manifest.
    @Test func refusesManifestJSONThatIsNotAnObject() {
        for json in ["[]", "[1, 2, 3]", "\"hello\"", "42"] {
            let data = XPIArchive(entries: [.init(name: "manifest.json", data: Data(json.utf8))]).data
            #expect(throws: XPIPackage.Failure.damaged, "\(json)") { try XPIPackage(data) }
        }
    }

    @Test func refusesAPackageWithoutAManifest() throws {
        let data = XPIArchive(entries: [.init(name: "background.js", data: Data("let a = 1;".utf8))]).data
        #expect(throws: XPIPackage.Failure.missingManifest) { try XPIPackage(data) }
    }

    @Test func refusesAManifestThatIsNotAtTheRoot() throws {
        let data = XPIArchive(entries: [.init(name: "extension/manifest.json", data: try Self.json(Self.manifest))]).data
        #expect(throws: XPIPackage.Failure.manifestNotAtRoot) { try XPIPackage(data) }
    }

    @Test func refusesAManifestThatIsNotJSON() {
        let data = XPIArchive(entries: [.init(name: "manifest.json", data: Data("not json".utf8))]).data
        #expect(throws: XPIPackage.Failure.damaged) { try XPIPackage(data) }
    }

    @Test func refusesAnEntryThatReachesOutside() throws {
        let data = XPIArchive(entries: [.init(name: "manifest.json", data: try Self.json(Self.manifest)),
                                     .init(name: "../escaped.txt", data: Data("x".utf8))]).data
        #expect(throws: XPIPackage.Failure.unsafeName("../escaped.txt")) { try XPIPackage(data) }
    }

    /// A package whose sibling entry is corrupt: reading it reads the manifest alone, while unpacking it reads the
    /// sibling and refuses. The corrupt entry is stored with a stale checksum, which the index checks only when the
    /// entry's bytes are read, so `entries` itself still accepts it.
    @Test func readsOnlyTheManifestOfAPackageWhoseSiblingIsCorrupt() throws {
        let marker = Data("corrupt-sibling-marker".utf8)
        var data = XPIArchive(entries: [
            .init(name: "manifest.json", data: try Self.json(Self.manifest)),
            .init(name: "notes.txt", data: marker),
        ]).data
        let found = try #require(data.range(of: marker))
        data[found.lowerBound] ^= 0xFF

        let package = try XPIPackage(data)
        #expect(package.manifest["name"] as? String == "Test")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("XPIPackageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: XPIPackage.Failure.damaged) { try package.unpack(into: folder) }
    }

    @Test func unpacksItsFilesIntoANewFolder() throws {
        let manifestData = try Self.json(Self.manifest)
        let package = try XPIPackage(XPIArchive(entries: [
            .init(name: "manifest.json", data: manifestData),
            .init(name: "js/background.js", data: Data("let a = 1;".utf8)),
        ]).data)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("XPIPackageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try package.unpack(into: folder)
        #expect(try Data(contentsOf: folder.appendingPathComponent("manifest.json")) == manifestData)
        #expect(try String(contentsOf: folder.appendingPathComponent("js/background.js"), encoding: .utf8) == "let a = 1;")
    }
}

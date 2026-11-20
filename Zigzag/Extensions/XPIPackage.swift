import Foundation

/// A Firefox package (.xpi): a zip whose `manifest.json` is at its root. A gecko ID in the manifest names it to
/// Firefox. The zip is read with the same package rules a Chrome extension gets, and unpacked the same way, so an
/// entry that climbs out of the folder is refused before anything is written.
nonisolated struct XPIPackage {
    enum Failure: Error, Equatable {
        case missingManifest
        case manifestNotAtRoot
        case unsafeName(String)
        case tooLarge
        case damaged
    }

    let manifest: [String: Any]
    let firefoxID: String?
    private let data: Data

    /// Reads the root `manifest.json`, decompressing only that entry: nothing else in the package is unpacked here.
    init(_ data: Data) throws {
        let entries = try Self.entries(data)
        // The manifest is the package's own, at its root: one under a folder is a zip of a folder, not an XPI.
        guard let manifestEntry = entries.first(where: { !$0.isDirectory && $0.path == ["manifest.json"] }) else {
            let manifestAnywhere = entries.contains { !$0.isDirectory && $0.path.last == "manifest.json" }
            throw manifestAnywhere ? Failure.manifestNotAtRoot : Failure.missingManifest
        }
        let contents: [UInt8]
        do { contents = try PackageZip.content(of: manifestEntry, in: [UInt8](data)) }
        catch let failure as PackageZip.Failure { throw Self.failure(failure) }
        guard PackageZip.crc32(contents) == manifestEntry.crc,
              let manifest = (try? JSONSerialization.jsonObject(with: Data(contents))) as? [String: Any] else {
            throw Failure.damaged
        }
        self.manifest = manifest
        self.firefoxID = Self.geckoID(of: manifest)
        self.data = data
    }

    /// Unpacks into a folder that must be new or empty, with the same checks the package was read with.
    func unpack(into folder: URL) throws {
        try Self.unpack(data, into: folder)
    }

    private static func entries(_ data: Data) throws -> [PackageZip.Entry] {
        do { return try PackageZip.entries(data) }
        catch let failure as PackageZip.Failure { throw Self.failure(failure) }
    }

    private static func unpack(_ data: Data, into folder: URL) throws {
        do { try PackageZip.unpack(data, into: folder) }
        catch let failure as PackageZip.Failure { throw Self.failure(failure) }
    }

    /// Every way a package can be wrong is the zip's, with the ones an XPI names kept apart.
    private static func failure(_ failure: PackageZip.Failure) -> Failure {
        switch failure {
        case .unsafeName(let name): .unsafeName(name)
        case .tooLarge: .tooLarge
        case .malformed, .unsupported, .notAFile, .duplicate, .damaged: .damaged
        }
    }

    /// `browser_specific_settings.gecko.id`, or the legacy `applications.gecko.id` before it.
    static func geckoID(of manifest: [String: Any]) -> String? {
        func id(under key: String) -> String? {
            ((manifest[key] as? [String: Any])?["gecko"] as? [String: Any])?["id"] as? String
        }
        return id(under: "browser_specific_settings") ?? id(under: "applications")
    }
}

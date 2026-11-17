import Foundation

/// A Firefox package (.xpi): a zip whose `manifest.json` is at its root. Mozilla signs some of them, which names the
/// extension an update belongs to as well as its files, and a gecko ID in the manifest names it to Firefox. The zip
/// is read with the same package rules a Chrome extension gets, and unpacked the same way, so an entry that climbs
/// out of the folder is refused before anything is written.
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
    let hasSignature: Bool
    private let data: Data

    init(_ data: Data) throws {
        let entries = try Self.entries(data)
        // The manifest is the package's own, at its root: one under a folder is a zip of a folder, not an XPI.
        guard entries.contains(where: { !$0.isDirectory && $0.path == ["manifest.json"] }) else {
            let manifestAnywhere = entries.contains { !$0.isDirectory && $0.path.last == "manifest.json" }
            throw manifestAnywhere ? Failure.manifestNotAtRoot : Failure.missingManifest
        }
        // PackageZip keeps its entry reader to itself, so the manifest is read as anything else in the package is:
        // unpacked into a folder of its own, which is then removed. Nothing is written beside the package.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-xpi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.unpack(data, into: folder)
        guard let contents = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: contents)) as? [String: Any] else {
            throw Failure.damaged
        }
        self.manifest = manifest
        self.firefoxID = Self.geckoID(of: manifest)
        self.hasSignature = entries.contains { !$0.isDirectory && $0.path == ["META-INF", "mozilla.rsa"] }
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
    private static func geckoID(of manifest: [String: Any]) -> String? {
        func id(under key: String) -> String? {
            ((manifest[key] as? [String: Any])?["gecko"] as? [String: Any])?["id"] as? String
        }
        return id(under: "browser_specific_settings") ?? id(under: "applications")
    }
}

import CryptoKit
import Foundation
import Testing
@testable import Zigzag

/// A real Chrome Web Store package (Custom Progress Bar for YouTube), used to check that only an intact,
/// correctly signed package for the expected extension is accepted.
struct CRXPackageTests {
    /// The real package is a third-party extension, kept out of the public repository; the tests that need it
    /// run only where it's present.
    nonisolated static var hasFixture: Bool { Bundle(for: Marker.self).url(forResource: "custom-progress-bar", withExtension: "crx") != nil }

    static let id = "nbkomboflhdlliegkaiepilnfmophgfg"

    static var fixture: Data {
        get throws {
            let url = try #require(Bundle(for: Marker.self).url(forResource: "custom-progress-bar", withExtension: "crx"))
            return try Data(contentsOf: url)
        }
    }

    @Test(.enabled(if: hasFixture)) func acceptsTheRealPackage() throws {
        let package = try CRXPackage(Self.fixture, expectedID: Self.id)
        #expect(package.id == Self.id)
        #expect(package.zip.prefix(2) == Data("PK".utf8))
    }

    @Test(.enabled(if: hasFixture)) func refusesAPackageForAnotherExtension() throws {
        #expect(throws: CRXPackage.Failure.wrongExtension) {
            try CRXPackage(Self.fixture, expectedID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        }
    }

    @Test(.enabled(if: hasFixture)) func refusesATamperedPackage() throws {
        var data = try Self.fixture
        // Flip one byte near the end of the zip: the signature no longer covers what we'd unpack.
        let index = data.count - 100
        data[index] ^= 0xFF
        #expect(throws: CRXPackage.Failure.unsigned) {
            try CRXPackage(data, expectedID: Self.id)
        }
    }

    // MARK: The store's own signature

    /// A package signed by its developer and, when given, by a key standing in for the store's.
    private static func signed(by developer: P256.Signing.PrivateKey, publisher: P256.Signing.PrivateKey?, publisherSignsSomethingElse: Bool = false) throws -> (data: Data, id: String) {
        func varint(_ value: Int) -> [UInt8] {
            var value = UInt64(value), out: [UInt8] = []
            while value >= 0x80 { out.append(UInt8(value & 0x7F) | 0x80); value >>= 7 }
            return out + [UInt8(value)]
        }
        func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(bytes.count) + bytes }
        let developerKey = [UInt8](developer.publicKey.derRepresentation)
        let crxID = Array(SHA256.hash(data: developerKey).prefix(16))
        let signedData = field(1, crxID)
        let archive = Data("PK\u{3}\u{4} the zip".utf8)
        var message = Data("CRX3 SignedData".utf8) + Data([0])
        var length = UInt32(signedData.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(contentsOf: signedData)
        message.append(archive)
        func proof(_ key: P256.Signing.PrivateKey, over signed: Data) throws -> [UInt8] {
            field(3, field(1, [UInt8](key.publicKey.derRepresentation)) + field(2, [UInt8](try key.signature(for: signed).derRepresentation)))
        }
        var header = try proof(developer, over: message)
        if let publisher { header += try proof(publisher, over: publisherSignsSomethingElse ? message + Data([1]) : message) }
        header += field(10000, signedData)
        var bytes: [UInt8] = Array("Cr24".utf8) + [3, 0, 0, 0]
        var headerLength = UInt32(header.count).littleEndian
        bytes += withUnsafeBytes(of: &headerLength) { Array($0) }
        return (Data(bytes + header) + archive, CRXPackage.extensionID(crxID))
    }

    @Test func takesAPackageOnlyWithTheStoresSignatureToo() throws {
        let developer = P256.Signing.PrivateKey(), store = P256.Signing.PrivateKey()
        let storeHash = Array(SHA256.hash(data: store.publicKey.derRepresentation))
        let both = try Self.signed(by: developer, publisher: store)
        #expect(try CRXPackage(both.data, expectedID: both.id, publisherKeyHash: storeHash).id == both.id)
        // Signed by its developer alone, as anyone can sign a package of their own.
        let alone = try Self.signed(by: developer, publisher: nil)
        #expect(throws: CRXPackage.Failure.notFromStore) { try CRXPackage(alone.data, expectedID: alone.id, publisherKeyHash: storeHash) }
        // The store's key, but its signature isn't over this package.
        let wrong = try Self.signed(by: developer, publisher: store, publisherSignsSomethingElse: true)
        #expect(throws: CRXPackage.Failure.notFromStore) { try CRXPackage(wrong.data, expectedID: wrong.id, publisherKeyHash: storeHash) }
        // Another key than the store's, however well it signs.
        let other = try Self.signed(by: developer, publisher: P256.Signing.PrivateKey())
        #expect(throws: CRXPackage.Failure.notFromStore) { try CRXPackage(other.data, expectedID: other.id, publisherKeyHash: storeHash) }
        // By default, it's the Chrome Web Store's key, as Chrome has it.
        #expect(throws: CRXPackage.Failure.notFromStore) { try CRXPackage(both.data, expectedID: both.id) }
        #expect(CRXPackage.webStoreKeyHash.map { String(format: "%02x", $0) }.joined() == "61f7f2a6bfcf74cd0bc1fe2497cc9b04254c658f79f2145392867ea8366367cf")
    }

    @Test func refusesAHeaderWithAnImpossibleLength() {
        // Field 2, length-delimited, with a length of 2^63 - 1: must be refused, never overflow.
        let header: [UInt8] = [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
        var bytes: [UInt8] = Array("Cr24".utf8) + [3, 0, 0, 0, UInt8(header.count), 0, 0, 0] + header
        bytes += [0x50, 0x4B]
        #expect(throws: CRXPackage.Failure.malformed) {
            try CRXPackage(Data(bytes), expectedID: Self.id)
        }
    }

    @Test func refusesSomethingThatIsntAPackage() {
        #expect(throws: CRXPackage.Failure.notCRX3) {
            try CRXPackage(Data("PK\u{3}\u{4} just a zip".utf8), expectedID: Self.id)
        }
    }

    @Test(.enabled(if: hasFixture)) func refusesATruncatedHeader() throws {
        let data = try Self.fixture.prefix(40)
        #expect(throws: CRXPackage.Failure.self) {
            try CRXPackage(Data(data), expectedID: Self.id)
        }
    }

    @Test func comparesChromeVersions() {
        #expect(ExtensionStore.isVersion("2026.1021.1354", newerThan: "2026.1015.900"))
        #expect(ExtensionStore.isVersion("1.10", newerThan: "1.9"))
        #expect(ExtensionStore.isVersion("1.0.1", newerThan: "1.0"))
        #expect(!ExtensionStore.isVersion("1.0", newerThan: "1.0.0"))
        #expect(!ExtensionStore.isVersion("8.12.42.36", newerThan: "8.12.42.36"))
    }
}

private final class Marker {}

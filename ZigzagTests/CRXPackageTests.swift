import Foundation
import Testing
@testable import Zigzag

/// A real Chrome Web Store package (Custom Progress Bar for YouTube), used to check that only an intact,
/// correctly signed package for the expected extension is accepted.
struct CRXPackageTests {
    /// The real package is a third-party extension, kept out of the public repository; the tests that need it
    /// run only where it's present.
    static var hasFixture: Bool { Bundle(for: Marker.self).url(forResource: "custom-progress-bar", withExtension: "crx") != nil }

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

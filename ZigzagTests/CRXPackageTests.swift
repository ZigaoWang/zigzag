import Foundation
import Testing
@testable import Zigzag

/// A real Chrome Web Store package (Custom Progress Bar for YouTube), used to check that only an intact,
/// correctly signed package for the expected extension is accepted.
struct CRXPackageTests {
    static let id = "nbkomboflhdlliegkaiepilnfmophgfg"

    static var fixture: Data {
        get throws {
            let url = try #require(Bundle(for: Marker.self).url(forResource: "custom-progress-bar", withExtension: "crx"))
            return try Data(contentsOf: url)
        }
    }

    @Test func acceptsTheRealPackage() throws {
        let package = try CRXPackage(Self.fixture, expectedID: Self.id)
        #expect(package.id == Self.id)
        #expect(package.zip.prefix(2) == Data("PK".utf8))
    }

    @Test func refusesAPackageForAnotherExtension() throws {
        #expect(throws: CRXPackage.Failure.wrongExtension) {
            try CRXPackage(Self.fixture, expectedID: "aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        }
    }

    @Test func refusesATamperedPackage() throws {
        var data = try Self.fixture
        // Flip one byte near the end of the zip: the signature no longer covers what we'd unpack.
        let index = data.count - 100
        data[index] ^= 0xFF
        #expect(throws: CRXPackage.Failure.unsigned) {
            try CRXPackage(data, expectedID: Self.id)
        }
    }

    @Test func refusesSomethingThatIsntAPackage() {
        #expect(throws: CRXPackage.Failure.notCRX3) {
            try CRXPackage(Data("PK\u{3}\u{4} just a zip".utf8), expectedID: Self.id)
        }
    }

    @Test func refusesATruncatedHeader() throws {
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

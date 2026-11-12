import Foundation
import Testing
import WebKit
@testable import Zigzag

/// A development server's own certificate (#141): trusted without the warning only with the setting on, for a
/// development site on this Mac, when a development page asks, and only the first one it shows.
@MainActor
@Suite(.serialized)
struct LocalServerTrustTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "LocalServerTrustTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removePersistentDomain(forName: name)
            DeveloperTools.defaults = saved
            DeveloperTools.changed.send()
        }
        try body()
    }

    private let page = URL(string: "https://localhost:8443/")
    private let elsewhere = URL(string: "https://example.com/")

    @Test func itIsOffUntilTurnedOn() {
        withDefaults {
            #expect(!DeveloperTools.trustsLocalServers)
            #expect(!DeveloperTools.trustsServer("localhost"))
            DeveloperTools.trustsLocalServers = true
            #expect(DeveloperTools.trustsServer("localhost"))
        }
    }

    @Test func onlyADevelopmentSiteOnThisMacIsTrusted() {
        withDefaults {
            DeveloperTools.trustsLocalServers = true
            #expect(DeveloperTools.trustsServer("localhost"))
            #expect(DeveloperTools.trustsServer("LOCALHOST"))
            #expect(DeveloperTools.trustsServer("app.localhost"))
            #expect(DeveloperTools.trustsServer("127.0.0.1"))
            // Listed, but looked up on the network: the warning stays, even for a name that starts like an address.
            DevelopmentSites.add("localtest.me")
            DevelopmentSites.add("nip.io")
            #expect(!DeveloperTools.trustsServer("app.localtest.me"))
            #expect(!DeveloperTools.trustsServer("127.0.0.1.nip.io"))
            #expect(!DeveloperTools.trustsServer("example.com"))
            #expect(!DeveloperTools.trustsServer("192.168.1.20"))
            // On this Mac, but taken off the list.
            DevelopmentSites.remove("localhost")
            #expect(!DeveloperTools.trustsServer("localhost"))
            #expect(DeveloperTools.trustsServer("127.0.0.1"))
            // An address in brackets, once it's listed.
            #expect(!DeveloperTools.trustsServer("::1"))
            DevelopmentSites.add("::1")
            #expect(DeveloperTools.trustsServer("::1"))
            // Not with Developer tools off.
            DeveloperTools.isOn = false
            #expect(!DeveloperTools.trustsServer("127.0.0.1"))
        }
    }

    @Test func anAddressOnThisMacIsAnAddressNotANameThatStartsLikeOne() throws {
        #expect(ErrorPage.isOnThisMac(try #require(URL(string: "http://127.0.0.1:3000/"))))
        #expect(ErrorPage.isOnThisMac(try #require(URL(string: "http://127.8.9.10/"))))
        #expect(!ErrorPage.isOnThisMac(try #require(URL(string: "http://127.0.0.1.nip.io/"))))
        #expect(!ErrorPage.isOnThisMac(try #require(URL(string: "http://127.example.com/"))))
        #expect(!ErrorPage.isOnThisMac(try #require(URL(string: "http://127.0.0.999/"))))
    }

    @Test func theFirstCertificateAServerShowsIsTheOneTrusted() {
        withDefaults {
            let store = WKWebsiteDataStore.nonPersistent()
            let first = Data([1, 2, 3]), second = Data([9, 9, 9])
            @MainActor func allows(_ leaf: Data?, host: String = "localhost", port: Int = 8443, by asker: URL?, in store: WKWebsiteDataStore) -> Bool {
                CertificateExceptions.allowsLocalServer(host, port: port, leaf: leaf, askedBy: asker, in: store)
            }
            // Off: as ever.
            #expect(!allows(first, by: page, in: store))
            DeveloperTools.trustsLocalServers = true
            #expect(!allows(nil, by: page, in: store))
            #expect(allows(first, by: page, in: store))
            #expect(allows(first, by: page, in: store))
            // Another certificate later in the session gets the warning.
            #expect(!allows(second, by: page, in: store))
            // Another server on the same host has its own.
            #expect(allows(second, port: 3000, by: page, in: store))
            #expect(allows(first, by: page, in: store))
            // Each store keeps its own, and no other host is touched.
            #expect(!allows(first, host: "example.com", by: page, in: store))
            #expect(allows(second, by: page, in: WKWebsiteDataStore.nonPersistent()))
            // Turned off: nothing is trusted this way, what was shown before included.
            DeveloperTools.trustsLocalServers = false
            #expect(!allows(first, by: page, in: store))
        }
    }

    @Test func onlyADevelopmentPagesOwnLoadsAreTrusted() {
        withDefaults {
            DeveloperTools.trustsLocalServers = true
            let store = WKWebsiteDataStore.nonPersistent()
            let leaf = Data([1])
            // A page from anywhere else that reaches for a server on this Mac gets what it always got.
            #expect(!CertificateExceptions.allowsLocalServer("localhost", port: 8443, leaf: leaf, askedBy: elsewhere, in: store))
            #expect(!CertificateExceptions.allowsLocalServer("localhost", port: 8443, leaf: leaf, askedBy: nil, in: store))
            #expect(CertificateExceptions.allowsLocalServer("localhost", port: 8443, leaf: leaf, askedBy: page, in: store))
        }
    }

    @Test func aSiteYouChoseToVisitIsTrustedAsBefore() {
        withDefaults {
            DeveloperTools.trustsLocalServers = true
            let store = WKWebsiteDataStore.nonPersistent()
            // What "Visit anyway" keeps is kept apart: trusting a development server never changes it.
            #expect(CertificateExceptions.allowsLocalServer("localhost", port: 8443, leaf: Data([1]), askedBy: page, in: store))
            CertificateExceptions.allow("localhost", certificate: Data([4, 5]), in: store)
            #expect(CertificateExceptions.allowsLocalServer("localhost", port: 8443, leaf: Data([1]), askedBy: page, in: store))
        }
    }
}

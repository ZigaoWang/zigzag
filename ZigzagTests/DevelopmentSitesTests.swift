import Foundation
import Testing
@testable import Zigzag

/// Developer tools (#141): the switch, the list of sites you develop on, and what counts as one of them.
@MainActor
@Suite(.serialized)
struct DevelopmentSitesTests {
    private func withDefaults(_ body: () throws -> Void) rethrows {
        let name = "DevelopmentSitesTests-\(UUID().uuidString)"
        let saved = DeveloperTools.defaults
        DeveloperTools.defaults = UserDefaults(suiteName: name)!
        defer {
            DeveloperTools.defaults.removePersistentDomain(forName: name)
            DeveloperTools.defaults = saved
            // Whatever heard a change made here (the app the tests run in) reads its own choices again.
            DeveloperTools.changed.send()
        }
        try body()
    }

    private func url(_ text: String) -> URL? { URL(string: text) }

    @Test func itStartsOnWithThisMacsOwnNamesAndWritesNothing() {
        withDefaults {
            #expect(DeveloperTools.isOn)
            #expect(DevelopmentSites.sites == ["127.0.0.1", "localhost"])
            #expect(DeveloperTools.applies(to: url("http://localhost:3000/")))
            #expect(DeveloperTools.defaults.object(forKey: "DevelopmentSites") == nil)
            #expect(DeveloperTools.defaults.object(forKey: "DeveloperTools") == nil)
        }
    }

    /// Site Controls offers the switch on a page being built, never on every site on the web.
    @Test func theSwitchIsOfferedOnlyWhereAPageLooksBeingBuilt() {
        withDefaults {
            for local in ["http://localhost:3000/", "http://127.0.0.1/", "https://myapp.test/", "http://printer.local/",
                          "http://192.168.1.20:8080/", "http://10.0.0.5/", "http://172.20.1.1/", "https://example.com:8443/",
                          "http://app.internal/", "http://box.lan/"] {
                #expect(DevelopmentSites.isSwitchOffered(for: url(local), isPrivate: false), "\(local)")
            }
            for web in ["https://example.com/", "http://example.com:80/", "https://github.com/", "http://172.32.0.1/",
                        "https://192.168.1.20.nip.io/", "https://10.0.0.5.example.com/"] {
                #expect(!DevelopmentSites.isSwitchOffered(for: url(web), isPrivate: false), "\(web)")
            }
            // Listed, any site has it, so it can be taken off there; never in a private window.
            DevelopmentSites.add("staging.example.com")
            #expect(DevelopmentSites.isSwitchOffered(for: url("https://staging.example.com/"), isPrivate: false))
            #expect(!DevelopmentSites.isSwitchOffered(for: url("http://localhost:3000/"), isPrivate: true))
        }
    }

    @Test func aSiteCoversEveryPortAndItsSubdomains() {
        withDefaults {
            #expect(DevelopmentSites.covers(url("http://localhost/")))
            #expect(DevelopmentSites.covers(url("https://localhost:8443/admin?x=1")))
            #expect(DevelopmentSites.covers(url("http://app.localhost:5173/")))
            #expect(DevelopmentSites.covers(url("http://127.0.0.1:8000/")))
            #expect(!DevelopmentSites.covers(url("http://127.0.0.2/")))
            #expect(!DevelopmentSites.covers(url("https://notlocalhost/")))
            #expect(!DevelopmentSites.covers(url("https://localhost.example.com/")))
            #expect(!DevelopmentSites.covers(url("https://example.com/")))
            #expect(DevelopmentSites.covers(url("http://localhost.:3000/")))
        }
    }

    @Test func anAddressInBracketsIsASiteToo() {
        withDefaults {
            #expect(!DevelopmentSites.covers(url("http://[::1]:3000/")))
            DevelopmentSites.add("::1")
            #expect(DevelopmentSites.covers(url("http://[::1]:3000/")))
            #expect(DevelopmentSites.covers(url("http://[::1]/")))
        }
    }

    @Test func onlyWebPagesAreCovered() {
        withDefaults {
            #expect(!DevelopmentSites.covers(nil))
            #expect(!DevelopmentSites.covers(url("file:///Users/me/site/index.html")))
            #expect(!DevelopmentSites.covers(url("zigzag://settings/developer")))
            #expect(!DevelopmentSites.covers(url("webkit-extension://localhost/popup.html")))
        }
    }

    @Test func offNothingIsADevelopmentPage() {
        withDefaults {
            DeveloperTools.isOn = false
            #expect(!DeveloperTools.applies(to: url("http://localhost:3000/")))
            #expect(DevelopmentSites.covers(url("http://localhost:3000/")))
            DeveloperTools.isOn = true
            #expect(DeveloperTools.applies(to: url("http://localhost:3000/")))
        }
    }

    @Test func aSiteAddedIsKeptWithTheOnesItCameWith() {
        withDefaults {
            DevelopmentSites.add("app.localtest.me")
            #expect(DevelopmentSites.sites == ["127.0.0.1", "app.localtest.me", "localhost"])
            #expect(DeveloperTools.defaults.stringArray(forKey: "DevelopmentSites") == ["127.0.0.1", "app.localtest.me", "localhost"])
            #expect(DevelopmentSites.covers(url("https://api.app.localtest.me/")))
            #expect(!DevelopmentSites.covers(url("https://other.localtest.me/")))
        }
    }

    @Test func aSiteAlreadyCoveredIsNotListedTwiceAndAParentTakesItsChildrensPlace() {
        withDefaults {
            DevelopmentSites.add("app.localhost")
            #expect(DevelopmentSites.sites == ["127.0.0.1", "localhost"])
            #expect(DeveloperTools.defaults.object(forKey: "DevelopmentSites") == nil)
            DevelopmentSites.add("app.localtest.me")
            DevelopmentSites.add("api.localtest.me")
            DevelopmentSites.add("localtest.me")
            #expect(DevelopmentSites.sites == ["127.0.0.1", "localhost", "localtest.me"])
        }
    }

    @Test func removingASiteThatIsNotListedChangesAndWritesNothing() {
        withDefaults {
            var heard = 0
            let token = DeveloperTools.changed.observe { heard += 1 }
            DevelopmentSites.remove("example.com")
            #expect(DevelopmentSites.sites == ["127.0.0.1", "localhost"])
            #expect(DeveloperTools.defaults.object(forKey: "DevelopmentSites") == nil)
            #expect(heard == 0)
            token.cancel()
        }
    }

    @Test func removingTheLastOnesLeavesAnEmptyListNotTheFirstOne() {
        withDefaults {
            DevelopmentSites.remove("localhost")
            DevelopmentSites.remove("127.0.0.1")
            #expect(DevelopmentSites.sites.isEmpty)
            #expect(!DevelopmentSites.covers(url("http://localhost/")))
        }
    }

    @Test func whatYouTypeBecomesASite() {
        #expect(DevelopmentSites.entry(from: "localhost:3000") == "localhost")
        #expect(DevelopmentSites.entry(from: "  http://App.LocalTest.me/x?y ") == "app.localtest.me")
        #expect(DevelopmentSites.entry(from: "https://www.staging.example.com") == "staging.example.com")
        #expect(DevelopmentSites.entry(from: "*.test") == "test")
        #expect(DevelopmentSites.entry(from: ".internal") == "internal")
        #expect(DevelopmentSites.entry(from: "192.168.1.20:8080") == "192.168.1.20")
        #expect(DevelopmentSites.entry(from: "[::1]:3000") == "::1")
        #expect(DevelopmentSites.entry(from: "") == nil)
        #expect(DevelopmentSites.entry(from: "   ") == nil)
        #expect(DevelopmentSites.entry(from: "my site") == nil)
        #expect(DevelopmentSites.entry(from: "http://") == nil)
    }

    @Test func aChangeIsAnnounced() {
        withDefaults {
            var heard = 0
            let token = DeveloperTools.changed.observe { heard += 1 }
            DeveloperTools.isOn = true
            #expect(heard == 0)
            DeveloperTools.isOn = false
            DevelopmentSites.add("example.test")
            DevelopmentSites.add("example.test")
            #expect(heard == 2)
            token.cancel()
        }
    }

    @Test func aTabOnAListedSiteIsADevelopmentTab() {
        withDefaults {
            let space = UUID()
            let local = Tab(url: url("http://localhost:3000/"), spaceID: space)
            let other = Tab(url: url("https://example.com/"), spaceID: space)
            #expect(local.isDevelopment)
            #expect(!other.isDevelopment)
            var changes = 0
            let token = other.changed.observe { if $0 == .developer { changes += 1 } }
            DevelopmentSites.add("example.com")
            other.refreshDevelopment()
            other.refreshDevelopment()
            #expect(other.isDevelopment)
            #expect(changes == 1)
            DeveloperTools.isOn = false
            other.refreshDevelopment()
            local.refreshDevelopment()
            #expect(!other.isDevelopment && !local.isDevelopment)
            #expect(changes == 2)
            token.cancel()
        }
    }
}

import Foundation
import Testing
@testable import Zigzag

/// A website data store made up of record names, each with its types.
@MainActor
private final class FakeStore: WebsiteDataClearing {
    var records: [String: Set<String>]
    var removedAll = false

    init(_ names: [String], types: Set<String> = WebsiteData.Kind.cookies.types) {
        records = Dictionary(uniqueKeysWithValues: names.map { ($0, types) })
    }

    func recordNames(ofTypes types: Set<String>) async -> [String] {
        records.filter { !$0.value.isDisjoint(with: types) }.map(\.key).sorted()
    }

    func removeData(ofTypes types: Set<String>, named names: Set<String>) async {
        for name in names { records[name] = records[name]?.subtracting(types) }
        records = records.filter { !$0.value.isEmpty }
    }

    func removeAllData(ofTypes types: Set<String>) async {
        removedAll = true
        records = records.mapValues { $0.subtracting(types) }.filter { !$0.value.isEmpty }
    }
}

@MainActor
@Suite(.serialized)
struct KeptCookiesTests {
    private let profile = UUID()

    private func withDefaults(_ body: () async throws -> Void) async rethrows {
        let name = "KeptCookiesTests-\(UUID().uuidString)"
        let saved = KeptCookies.defaults
        KeptCookies.defaults = UserDefaults(suiteName: name)!
        defer {
            KeptCookies.defaults.removeScratchSuite(name)
            KeptCookies.defaults = saved
        }
        try await body()
    }

    // MARK: Sites

    @Test func aSiteIsItsRegistrableDomainWithoutWWW() {
        #expect(KeptCookies.site(of: URL(string: "https://www.github.com/settings")) == "github.com")
        #expect(KeptCookies.site(of: URL(string: "http://github.com/")) == "github.com")
        #expect(KeptCookies.site(of: URL(string: "https://gist.github.com/")) == "github.com")
        #expect(KeptCookies.site(of: URL(string: "https://news.bbc.co.uk/")) == "bbc.co.uk")
        #expect(KeptCookies.site(of: URL(string: "https://WWW.Example.COM./")) == "example.com")
    }

    @Test func localAddressesAreTheirOwnSite() {
        #expect(KeptCookies.site(of: URL(string: "http://localhost:8000/")) == "localhost")
        #expect(KeptCookies.site(of: URL(string: "http://127.0.0.1:8000/")) == "127.0.0.1")
        #expect(KeptCookies.site(of: URL(string: "http://[::1]:8000/")) == "::1")
    }

    @Test func onlyWebPagesHaveASite() {
        #expect(KeptCookies.site(of: URL(string: "file:///Users/me/page.html")) == nil)
        #expect(KeptCookies.site(of: URL(string: "zigzag://settings")) == nil)
        #expect(KeptCookies.site(of: nil) == nil)
        #expect(!KeptCookies.isOffered(for: URL(string: "about:blank"), isPrivate: false))
        #expect(KeptCookies.isOffered(for: URL(string: "https://github.com"), isPrivate: false))
        #expect(!KeptCookies.isOffered(for: URL(string: "https://github.com"), isPrivate: true))
    }

    @Test func typedAddressesBecomeASite() {
        #expect(KeptCookies.entry(from: "github.com") == "github.com")
        #expect(KeptCookies.entry(from: "  https://www.github.com/login ") == "github.com")
        #expect(KeptCookies.entry(from: "http://mail.google.com") == "google.com")
        #expect(KeptCookies.entry(from: "localhost:8000") == "localhost")
        #expect(KeptCookies.entry(from: "") == nil)
        #expect(KeptCookies.entry(from: "git hub.com") == nil)
    }

    @Test func aKeptSiteCoversItsSubdomainsOnly() {
        let kept: Set = ["github.com", "localhost"]
        #expect(KeptCookies.covers(kept, record: "github.com"))
        #expect(KeptCookies.covers(kept, record: "gist.github.com"))
        #expect(KeptCookies.covers(kept, record: "WWW.GitHub.com"))
        #expect(KeptCookies.covers(kept, record: "localhost"))
        #expect(!KeptCookies.covers(kept, record: "notgithub.com"))
        #expect(!KeptCookies.covers(kept, record: "github.io"))
        #expect(!KeptCookies.covers(kept, record: "127.0.0.1"))
    }

    @Test func httpAndHttpsAreOneEntry() async {
        await withDefaults {
            KeptCookies.set(true, for: URL(string: "http://github.com"), in: profile, isPrivate: false)
            KeptCookies.set(true, for: URL(string: "https://www.github.com"), in: profile, isPrivate: false)
            #expect(KeptCookies.sites(in: profile) == ["github.com"])
            #expect(KeptCookies.keeps(URL(string: "https://gist.github.com/x"), in: profile))
            KeptCookies.set(false, for: URL(string: "http://gist.github.com"), in: profile, isPrivate: false)
            #expect(KeptCookies.sites(in: profile).isEmpty)
        }
    }

    // MARK: The list

    @Test func eachProfileKeepsItsOwnList() async {
        await withDefaults {
            let other = UUID()
            KeptCookies.add("github.com", in: profile)
            KeptCookies.add("localhost", in: other)
            #expect(KeptCookies.sites(in: profile) == ["github.com"])
            #expect(KeptCookies.sites(in: other) == ["localhost"])
            #expect(KeptCookies.defaults.stringArray(forKey: ProfileKey.keptCookieSites.name(in: profile)) == ["github.com"])
            KeptCookies.remove("github.com", in: profile)
            #expect(KeptCookies.sites(in: profile).isEmpty)
            #expect(KeptCookies.defaults.object(forKey: ProfileKey.keptCookieSites.name(in: profile)) == nil)
        }
    }

    @Test func aPrivateWindowNeverAddsASite() async {
        await withDefaults {
            KeptCookies.set(true, for: URL(string: "https://github.com"), in: profile, isPrivate: true)
            #expect(KeptCookies.sites(in: profile).isEmpty)
            #expect(KeptCookies.defaults.object(forKey: ProfileKey.keptCookieSites.name(in: profile)) == nil)
        }
    }

    @Test func changesAreSignaled() async {
        await withDefaults {
            var count = 0
            let token = KeptCookies.changed.observe { count += 1 }
            KeptCookies.add("github.com", in: profile)
            KeptCookies.add("github.com", in: profile)
            KeptCookies.remove("github.com", in: profile)
            #expect(count == 2)
            token.cancel()
        }
    }

    // MARK: Clearing

    @Test func clearingWithNothingKeptClearsEverything() async {
        let store = FakeStore(["github.com", "localhost", "example.com"])
        let removed = await KeptCookies.clear(WebsiteData.Kind.cookies.types, keeping: [], in: store)
        #expect(removed == nil)
        #expect(store.removedAll)
        #expect(store.records.isEmpty)
    }

    @Test func clearingLeavesTheKeptSitesAlone() async {
        let store = FakeStore(["github.com", "gist.github.com", "localhost", "127.0.0.1", "example.com", "notgithub.com"])
        let removed = await KeptCookies.clear(WebsiteData.Kind.cookies.types, keeping: ["github.com", "localhost"], in: store)
        #expect(Set(removed ?? []) == ["127.0.0.1", "example.com", "notgithub.com"])
        #expect(!store.removedAll)
        #expect(Set(store.records.keys) == ["github.com", "gist.github.com", "localhost"])
    }

    @Test func clearingCookiesLeavesOtherKindsOfData() async {
        let cache = WebsiteData.Kind.cache.types
        let store = FakeStore(["example.com"], types: WebsiteData.Kind.cookies.types.union(cache))
        await KeptCookies.clear(WebsiteData.Kind.cookies.types, keeping: ["github.com"], in: store)
        #expect(store.records["example.com"] == cache)
    }

    // MARK: Quitting

    @Test func clearingAtQuitIsOffUntilChosen() async {
        await withDefaults {
            let other = UUID()
            #expect(!KeptCookies.clearsOnQuit(in: profile))
            KeptCookies.setClearsOnQuit(true, in: profile)
            #expect(KeptCookies.clearsOnQuit(in: profile))
            #expect(!KeptCookies.clearsOnQuit(in: other))
            #expect(KeptCookies.defaults.bool(forKey: ProfileKey.clearsCookiesOnQuit.name(in: profile)))
            KeptCookies.setClearsOnQuit(false, in: profile)
            #expect(!KeptCookies.clearsOnQuit(in: profile))
            #expect(KeptCookies.defaults.object(forKey: ProfileKey.clearsCookiesOnQuit.name(in: profile)) == nil)
        }
    }

    /// Site Controls follows the switch while open (#383).
    @Test func turningClearingAtQuitSaysWhichProfile() async {
        await withDefaults {
            var heard: [UUID] = []
            let token = KeptCookies.clearingChanged.observe { heard.append($0) }
            KeptCookies.setClearsOnQuit(true, in: profile)
            KeptCookies.setClearsOnQuit(false, in: profile)
            token.cancel()
            #expect(heard == [profile, profile])
        }
    }

    @Test func quittingWaitsForTheClearing() async {
        let store = FakeStore(["github.com", "example.com"])
        var calls = 0
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            KeptCookies.whenDone([{ await KeptCookies.clear(WebsiteData.Kind.cookies.types, keeping: ["github.com"], in: store) }], within: 5) {
                calls += 1
                finished.resume()
            }
        }
        #expect(calls == 1)
        #expect(Array(store.records.keys) == ["github.com"])
    }

    @Test func quittingWaitsOnlySoLong() async {
        let start = Date()
        var calls = 0
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            KeptCookies.whenDone([{ try? await Task.sleep(for: .seconds(1)) }], within: 0.1) {
                calls += 1
                finished.resume()
            }
        }
        #expect(Date().timeIntervalSince(start) < 0.9)
        #expect(calls == 1)
        // The late job finishing later doesn't call it again.
        try? await Task.sleep(for: .seconds(1.2))
        #expect(calls == 1)
    }

    @Test func theQuitWaitIsShort() {
        #expect(KeptCookies.quitWait <= 2)
    }

    // MARK: Words

    @Test func theSheetSaysHowManySitesAreKept() {
        #expect(KeptCookies.clearMessage(keeping: 2).contains("2"))
        #expect(!KeptCookies.clearMessage(keeping: 1).contains("1"))
    }
}

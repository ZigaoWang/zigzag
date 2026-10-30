import Foundation
import Testing
@testable import Zigzag

/// The rules behind fixes that people would only notice going wrong: what Try Again re-runs, which saved logins
/// may fill where, and old data from a newer version still reading.
@MainActor
struct ShipFixesTests {
    @Test func tryAgainRunsOnlyWhatFailed() {
        let all: ImportCoordinator.Choice = [.passwords, .bookmarks, .history]
        // Chrome's passwords stayed locked: only passwords again, never history (which would double the counts).
        let locked = ImportProblem(message: "", fix: .retry, retries: ImportCoordinator.Choice.passwords.rawValue)
        #expect(ImportCoordinator.Choice.retrying([locked], else: all) == .passwords)
        // A primary password is about passwords too.
        let primary = ImportProblem(message: "", fix: .primaryPassword)
        #expect(ImportCoordinator.Choice.retrying([primary], else: all) == .passwords)
        // A problem that doesn't say what failed: everything, as before.
        let unknown = ImportProblem(message: "", fix: .retry)
        #expect(ImportCoordinator.Choice.retrying([unknown], else: all) == all)
        // Nothing to retry: everything.
        #expect(ImportCoordinator.Choice.retrying([], else: all) == all)
    }

    @Test func oldHTTPLoginsFillOnTheSecureSiteOnly() throws {
        let http = try #require(Origin(URL(string: "http://example.com/login")))
        let https = try #require(Origin(URL(string: "https://example.com/")))
        let other = try #require(Origin(URL(string: "https://example.org/")))
        let port = try #require(Origin(URL(string: "https://example.com:8443/")))
        #expect(https.fills(on: https))
        #expect(http.fills(on: https))       // upgraded to the secure page
        #expect(!https.fills(on: http))      // never the other way round
        #expect(!http.fills(on: other))      // never another site
        #expect(!http.fills(on: port))       // nor another port
    }

    @Test func unknownSpaceColourStillReads() throws {
        let json = Data(#"["sky", "ultraviolet", "mint"]"#.utf8)
        let colours = try JSONDecoder().decode([SpaceColor].self, from: json)
        #expect(colours == [.sky, .graphite, .mint])
    }
}

/// Passwords across one site's parts, never across sites, by the Public Suffix List.
struct SiteMatchingTests {
    @Test func findsTheRegistrableDomain() {
        #expect(PublicSuffix.registrableDomain("www.netflix.com") == "netflix.com")
        #expect(PublicSuffix.registrableDomain("news.bbc.co.uk") == "bbc.co.uk")
        #expect(PublicSuffix.registrableDomain("alice.github.io") == "alice.github.io")
        #expect(PublicSuffix.registrableDomain("co.uk") == nil)
        #expect(PublicSuffix.registrableDomain("github.io") == nil)
        #expect(PublicSuffix.registrableDomain("192.168.1.1") == nil)
        #expect(PublicSuffix.registrableDomain("localhost") == nil)
    }

    @Test func fillsAcrossOneSiteOnly() {
        func origin(_ s: String) -> Origin { Origin(URL(string: s))! }
        #expect(origin("https://www.netflix.com").fills(on: origin("https://netflix.com")))
        #expect(origin("https://m.facebook.com").fills(on: origin("https://www.facebook.com")))
        #expect(origin("http://www.example.com").fills(on: origin("https://login.example.com")))
        #expect(!origin("https://login.example.com").fills(on: origin("http://www.example.com")))   // never onto an insecure page
        #expect(!origin("https://alice.github.io").fills(on: origin("https://bob.github.io")))     // different owners
        #expect(!origin("https://bbc.co.uk").fills(on: origin("https://evil.co.uk")))
        #expect(!origin("https://example.com").fills(on: origin("https://example.com.evil.net")))
        #expect(!origin("https://example.com:8443").fills(on: origin("https://www.example.com")))
    }
}

/// Folders of pinned pages: kept together, in order, never holding pages that are gone.
struct BookmarkFolderTests {
    private func pages(_ names: String...) -> [Bookmark] { names.map { Bookmark(url: URL(string: "https://\($0).com")!, title: $0) } }

    @Test func gathersAFoldersPagesWhereTheFirstIs() {
        let b = pages("a", "b", "c", "d", "e")
        let folder = BookmarkFolder(name: "Work", bookmarkIDs: [b[3].id, b[1].id])
        let (list, folders) = Library.tidied(b, [folder])
        #expect(list.map(\.title) == ["a", "b", "d", "c", "e"])
        #expect(folders[0].bookmarkIDs == [b[1].id, b[3].id])   // the list's order
    }

    @Test func forgetsPagesThatAreGone() {
        let b = pages("a", "b")
        let gone = UUID()
        let (list, folders) = Library.tidied(b, [BookmarkFolder(name: "F", bookmarkIDs: [gone, b[1].id])])
        #expect(list.map(\.title) == ["a", "b"])
        #expect(folders[0].bookmarkIDs == [b[1].id])
    }

    @Test func leavesLoosePagesAndEmptyFoldersAlone() {
        let b = pages("a", "b", "c")
        let (list, folders) = Library.tidied(b, [BookmarkFolder(name: "Empty")])
        #expect(list.map(\.title) == ["a", "b", "c"])
        #expect(folders.count == 1 && folders[0].bookmarkIDs.isEmpty)
    }

    @Test func keepsTwoFoldersApart() {
        let b = pages("a", "b", "c", "d")
        let one = BookmarkFolder(name: "1", bookmarkIDs: [b[0].id, b[2].id])
        let two = BookmarkFolder(name: "2", bookmarkIDs: [b[1].id, b[3].id])
        let (list, _) = Library.tidied(b, [one, two])
        #expect(list.map(\.title) == ["a", "c", "b", "d"])
    }

    @Test func olderLibrariesWithoutFoldersStillLoad() throws {
        let json = Data(#"{"id":"6B1E4C1E-0000-4000-8000-000000000002","name":"Home","color":"sky","bookmarks":[]}"#.utf8)
        let space = try JSONDecoder().decode(SpaceInfo.self, from: json)
        #expect(space.folders == nil)
    }

    // MARK: Swiping between spaces

    @Test func swipeFollowsTheFingersAndComesBack() {
        // One to one toward a neighbor, so a small move and back leaves the list where it was.
        #expect(SpaceSwipe.offset(forTravel: 12, width: 300, hasLeft: true, hasRight: true) == 12)
        #expect(SpaceSwipe.offset(forTravel: -40, width: 300, hasLeft: true, hasRight: true) == -40)
        #expect(SpaceSwipe.landing(offset: 12, velocity: 0, width: 300) == 0)
        // Never more than a full width.
        #expect(SpaceSwipe.offset(forTravel: 900, width: 300, hasLeft: true, hasRight: true) == 300)
    }

    @Test func swipeLandsPastAThirdOrOnAFlick() {
        // Moving right brings in the space on the left.
        #expect(SpaceSwipe.landing(offset: 106, velocity: 0, width: 300) == -1)
        #expect(SpaceSwipe.landing(offset: -106, velocity: 0, width: 300) == 1)
        #expect(SpaceSwipe.landing(offset: 104, velocity: 0, width: 300) == 0)
        // A short flick that way lands; flicking back home doesn't, however far it went.
        #expect(SpaceSwipe.landing(offset: -30, velocity: -900, width: 300) == 1)
        #expect(SpaceSwipe.landing(offset: 200, velocity: -900, width: 300) == 0)
    }

    @Test func swipeHoldsBackAtTheEnds() {
        // No space on the left: the list gives less and less, and never past half the width.
        let small = SpaceSwipe.offset(forTravel: 30, width: 300, hasLeft: false, hasRight: true)
        let far = SpaceSwipe.offset(forTravel: 3000, width: 300, hasLeft: false, hasRight: true)
        #expect(small > 0 && small < 30)
        #expect(far > small && far < 150)
        #expect(SpaceSwipe.offset(forTravel: -30, width: 300, hasLeft: true, hasRight: false) == -small)
        // Picking a held-back list up again puts it where it was.
        let travel = SpaceSwipe.travel(toOffset: small, width: 300, hasLeft: false, hasRight: true)
        #expect(abs(travel - 30) < 0.001)
    }

    @Test func swipeSpeedComesFromTheLastMoment() {
        let samples: [(time: TimeInterval, dx: CGFloat)] = [(0, 50), (0.95, 0), (0.96, 10), (0.97, 10), (0.98, 10)]
        #expect(abs(SpaceSwipe.velocity(samples, at: 0.98) - 1000) < 0.001)
        // Fingers that stopped before letting go aren't moving.
        #expect(SpaceSwipe.velocity(samples, at: 2) == 0)
    }

    @Test func clearingTheLastHourKeepsOlderPDFPlaces() {
        let now = Date()
        let all: [String: Any] = [
            "old.pdf": [3, now.addingTimeInterval(-7200).timeIntervalSince1970],
            "new.pdf": [5, now.addingTimeInterval(-60).timeIntervalSince1970],
            "untimed.pdf": [7],
        ]
        let kept = PDFViewerView.places(all, readBefore: now.addingTimeInterval(-3600))
        #expect(Set(kept.keys) == ["old.pdf", "untimed.pdf"])
    }

    @Test func certificateProceedNeedsTheNonceAndTheWarnedHost() throws {
        let page = try #require(URL(string: "https://router.local:8443/admin?tab=1"))
        let link = try #require(CertificateExceptions.proceedLink(for: page, nonce: "abc"))
        #expect(link.scheme == CertificateExceptions.scheme)
        // The warning's own link goes back to the page it was for, nonce stripped.
        #expect(CertificateExceptions.destination(of: link, warnedHost: "router.local", nonce: "abc") == page)
        // A made-up link: no nonce, the wrong one, or a host the tab never warned about.
        let bare = try #require(URL(string: "zigzag-proceed://router.local:8443/admin"))
        #expect(CertificateExceptions.destination(of: bare, warnedHost: "router.local", nonce: "abc") == nil)
        #expect(CertificateExceptions.destination(of: link, warnedHost: "router.local", nonce: "xyz") == nil)
        #expect(CertificateExceptions.destination(of: link, warnedHost: "bank.com", nonce: "abc") == nil)
        #expect(CertificateExceptions.destination(of: link, warnedHost: nil, nonce: "abc") == nil)
        let plain = try #require(URL(string: "https://router.local/"))
        let plainLink = try #require(CertificateExceptions.proceedLink(for: plain, nonce: "abc"))
        #expect(CertificateExceptions.destination(of: plainLink, warnedHost: "router.local", nonce: "abc") == plain)
    }
}

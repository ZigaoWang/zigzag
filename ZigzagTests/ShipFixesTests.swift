import Foundation
import WebKit
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

    @Test func aPageInFullScreenKeepsTheSizeWebKitGaveIt() {
        let card = PageCardView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let webView = WKWebView(frame: .zero)
        card.show(webView)
        card.layoutSubtreeIfNeeded()
        #expect(webView.frame.size == NSSize(width: 800, height: 600))
        // A video goes full screen: WebKit takes the page into a window of its own, the size of the screen.
        let screen = NSView(frame: NSRect(x: 0, y: 0, width: 1512, height: 949))
        screen.addSubview(webView)
        webView.frame = screen.bounds
        // The card lays itself out meanwhile (the page shown changes, the window resizes): the page isn’t its to size.
        card.showsHeader = false
        card.setFrameSize(NSSize(width: 700, height: 500))
        card.layoutSubtreeIfNeeded()
        #expect(webView.frame == screen.bounds)
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

    @Test func keepsASubfolderInsideItsParent() {
        let b = pages("a", "b", "c", "d", "e")
        let outer = BookmarkFolder(name: "Outer", bookmarkIDs: [b[1].id])
        var inner = BookmarkFolder(name: "Inner", bookmarkIDs: [b[4].id, b[3].id])
        inner.parentID = outer.id
        let (list, folders) = Library.tidied(b, [outer, inner])
        // Outer's own page, then Inner's pages, all together where Outer's first page was.
        #expect(list.map(\.title) == ["a", "b", "d", "e", "c"])
        #expect(folders.pages(in: outer.id) == Set([b[1].id, b[3].id, b[4].id]))
        #expect(folders.depth(of: inner.id) == 1)
    }

    @Test func aFolderNeverEndsUpInsideItself() {
        let b = pages("a", "b")
        var one = BookmarkFolder(name: "1", bookmarkIDs: [b[0].id])
        var two = BookmarkFolder(name: "2", bookmarkIDs: [b[1].id])
        one.parentID = two.id
        two.parentID = one.id
        let (list, folders) = Library.tidied(b, [one, two])
        #expect(list.count == 2)
        #expect(folders.contains { $0.parentID == nil })
    }

    @Test func anEmptySubfolderSitsAtTheTopOfItsParent() {
        let b = pages("a", "b")
        let outer = BookmarkFolder(name: "Outer", bookmarkIDs: [b[0].id, b[1].id])
        var empty = BookmarkFolder(name: "Empty")
        empty.parentID = outer.id
        let (list, folders) = Library.tidied(b, [outer, empty])
        #expect(list.map(\.title) == ["a", "b"])
        #expect(folders.children(of: outer.id).map(\.name) == ["Empty"])
    }

    @Test func olderLibrariesWithoutFoldersStillLoad() throws {
        let json = Data(#"{"id":"6B1E4C1E-0000-4000-8000-000000000002","name":"Home","color":"sky","bookmarks":[]}"#.utf8)
        let space = try JSONDecoder().decode(SpaceInfo.self, from: json)
        #expect(space.folders == nil)
    }

    // MARK: Swiping back and forward

    private func decide(dx: CGFloat, dy: CGFloat = 0, back: Bool = true, forward: Bool = false,
                        scrolls: (left: Bool, right: Bool)? = (false, false), page: SwipeDecision.Page = .left,
                        waited: TimeInterval = 0.02) -> SwipeDecision {
        SwipeDecision.decide(dx: dx, dy: dy, canGoBack: back, canGoForward: forward, pageScrolls: scrolls, page: page, waited: waited)
    }

    @Test func swipeGoesBackOnAPlainPage() {
        // Fingers to the right go back, once they've gone far enough to tell.
        #expect(decide(dx: 4) == .undecided)
        #expect(decide(dx: 14) == .track(-1))
        #expect(decide(dx: -14, forward: true) == .track(1))
        // Nowhere to go, or mostly down the page: a scroll.
        #expect(decide(dx: -14) == .ignore)
        #expect(decide(dx: 14, dy: 13) == .ignore)
        // A page that scrolls sideways that way keeps it.
        #expect(decide(dx: 14, scrolls: (true, false)) == .ignore)
        #expect(decide(dx: 14, scrolls: (false, true)) == .track(-1))
    }

    @Test func swipeLeavesPagesThatPanThemselves() {
        // Canva, Figma, Google Maps: the page cancelled the gesture's sideways scrolls, so it has the gesture, even
        // before the fingers have gone far.
        #expect(decide(dx: 4, page: .took) == .ignore)
        #expect(decide(dx: 40, page: .took) == .ignore)
        #expect(decide(dx: -40, forward: true, page: .took) == .ignore)
    }

    @Test func swipeWaitsBrieflyForThePagesAnswer() {
        // Not heard from the page yet: a moment's wait, with the page still getting the gesture, then on without it.
        #expect(decide(dx: 14, page: .unknown, waited: 0.01) == .undecided)
        #expect(decide(dx: 14, page: .unknown, waited: SwipeDecision.answerWait) == .track(-1))
        // An answer that it left them ends the wait at once.
        #expect(decide(dx: 14, page: .left, waited: 0.001) == .track(-1))
        // Nothing to wait for when the swipe couldn't go anyway.
        #expect(decide(dx: -14, page: .unknown, waited: 0.001) == .ignore)
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

    @Test func errorPagesSayItPlainly() throws {
        let url = try #require(URL(string: "https://example.com:25/"))
        let errors = [NSError(domain: "WebKitErrorDomain", code: 103, userInfo: [NSLocalizedDescriptionKey: "Not allowed to use restricted network port"]),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed),
                      NSError(domain: NSURLErrorDomain, code: -99999, userInfo: [NSLocalizedDescriptionKey: "raw system text"])]
        for error in errors {
            let (title, message) = ErrorPage.describe(error, url: url)
            #expect(!title.isEmpty)
            #expect(message.hasSuffix("."))
            #expect(message != error.localizedDescription)
        }
        // A lookup failure names both likely causes.
        let dns = ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost), url: url).1
        #expect(dns.contains("internet") && dns.contains("typo"))
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

    @Test func buttonNamesLeaveOutTheirShortcut() {
        #expect(IconButton.withoutShortcut("Back (⌘[)") == "Back")
        #expect(IconButton.withoutShortcut("Hide Sidebar (⌥⌘S)") == "Hide Sidebar")
        #expect(IconButton.withoutShortcut("Downloads") == "Downloads")
    }

    @Test func onlyFrontPagesReplaceASitesIcon() throws {
        let artifact = try #require(URL(string: "https://claude.ai/artifact/4TsSgQ42Jkne"))
        // An artifact wears its own icon; once Claude has one, the artifact's never replaces it.
        #expect(!FaviconStore.speaksForSite(artifact, hasIcon: true))
        // With no icon yet, any page's is better than a globe.
        #expect(FaviconStore.speaksForSite(artifact, hasIcon: false))
        // The front page (where claude.ai lands) and the bare host do replace it.
        #expect(FaviconStore.speaksForSite(try #require(URL(string: "https://claude.ai/new")), hasIcon: true))
        #expect(FaviconStore.speaksForSite(try #require(URL(string: "https://github.com")), hasIcon: true))
    }

    @Test func suggestionsStayOnTheMacWhenOff() throws {
        // On: a search is sent to the engine for suggestions.
        #expect(SuggestionFetcher.url(for: "shanghai metro", engine: .google, isOn: true) != nil)
        // Off: nothing is sent, for any engine.
        for engine in SearchEngine.allCases {
            #expect(SuggestionFetcher.url(for: "shanghai metro", engine: engine, isOn: false) == nil)
        }
        // Addresses and single letters never were.
        #expect(SuggestionFetcher.url(for: "github.com", engine: .google, isOn: true) == nil)
        #expect(SuggestionFetcher.url(for: "s", engine: .google, isOn: true) == nil)
    }

    @Test func linkStatusShowsTheWholeAddress() throws {
        let link = try #require(URL(string: "https://www.iana.org/domains/reserved/rfc6761?x=1"))
        #expect(LinkStatusController.describe(link) == "iana.org/domains/reserved/rfc6761?x=1")
        #expect(LinkStatusController.describe(try #require(URL(string: "https://example.com/")))  == "example.com")
        #expect(LinkStatusController.describe(try #require(URL(string: "mailto:a@example.com"))) == "Email a@example.com")
    }

    @Test func aCutOffSecureConnectionIsNotCalledAnImpostor() throws {
        let url = try #require(URL(string: "https://example.com/"))
        let cutOff = ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed), url: url)
        #expect(!cutOff.0.contains("private"))
        let forged = ErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted), url: url)
        #expect(forged.0 == "This connection isn’t private")
    }

    @Test func theEmojiFieldTakesEmojiOfEveryKind() {
        for emoji in ["😀", "❤️", "☀️", "✈️", "✌️", "1️⃣", "👍🏽", "🇯🇵"] {
            #expect(IconGrid.lastEmoji(in: emoji) == emoji)
        }
        // The last one typed.
        #expect(IconGrid.lastEmoji(in: "😀a🚀b") == "🚀")
        // A plain digit, "#" or "*" counts as emoji in Unicode, but isn't one to look at.
        for text in ["abc", "1", "#", "*", "©", ""] {
            #expect(IconGrid.lastEmoji(in: text) == nil)
        }
    }

    @Test func anImportSaysWhichPasswordsItKept() {
        var summary = ImportCoordinator.Summary(source: "Passwords.csv")
        summary.passwords = 2
        summary.keptPasswords = 3
        #expect(summary.sentence == "Imported 2 passwords from Passwords.csv. Kept 3 passwords already in Zigzag instead of the imported ones.")
        summary.passwords = 0
        summary.keptPasswords = 1
        #expect(summary.sentence == "Nothing new to bring over from Passwords.csv. Kept 1 password already in Zigzag instead of the imported one.")
    }
}

/// The profile backup made when a new version first runs, and the restore that puts one back: in a folder of their
/// own, never the real profile.
struct ProfileBackupTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func backsUpOnceWhenTheBuildChanges() throws {
        let root = try makeRoot()
        let suite = "zigzag-backup-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        // A first run, with no profile yet: nothing to back up, only the build noted.
        ProfileBackup.backUpIfUpdated(build: "18", version: "0.4.0", defaults: defaults, root: root)
        #expect(ProfileBackup.all(in: root).isEmpty)
        try "spaces".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        // The same build again: still nothing.
        ProfileBackup.backUpIfUpdated(build: "18", version: "0.4.0", defaults: defaults, root: root)
        #expect(ProfileBackup.all(in: root).isEmpty)
        // A new build: one backup, named for the version it came from.
        ProfileBackup.backUpIfUpdated(build: "19", version: "0.5.0", defaults: defaults, root: root)
        let backups = ProfileBackup.updates(in: root)
        #expect(backups.count == 1)
        #expect(backups.first?.lastPathComponent.hasSuffix("Z 0.4.0") == true)
        #expect(backups.first.flatMap { read($0.appendingPathComponent("Library.json")) } == "spaces")
        ProfileBackup.backUpIfUpdated(build: "19", version: "0.5.0", defaults: defaults, root: root)
        #expect(ProfileBackup.all(in: root).count == 1)
    }

    @Test func namesSortByTimeAcrossTheOldAndNewStamps() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        let names = ["2026-10-01T10-00-00 0.3.0", "2026-10-03T08-00-00Z 0.5.0 before restore", "2026-10-02T09-00-00Z 0.4.0"]
        for name in names { try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true) }
        #expect(ProfileBackup.all(in: root).map(\.lastPathComponent) == [names[1], names[2], names[0]])
        // A restore puts back an update's backup, never the one made just before a restore.
        #expect(ProfileBackup.updates(in: root).map(\.lastPathComponent) == [names[2], names[0]])
        #expect(ProfileBackup.date(of: names[2]) == ISO8601DateFormatter().date(from: "2026-10-02T09:00:00Z"))
        #expect(ProfileBackup.date(of: "not a backup") == nil)
    }

    @Test func restoreKeepsWhatWasThereAndSwapsWholeFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "now".write(to: root.appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try "journal".write(to: root.appendingPathComponent("History.sqlite-wal"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("Backups", isDirectory: true)
        let name = "2026-10-02T09-00-00Z 0.4.0"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        try "then".write(to: folder.appendingPathComponent(name).appendingPathComponent("Library.json"), atomically: true, encoding: .utf8)
        try name.write(to: folder.appendingPathComponent("Restore"), atomically: true, encoding: .utf8)

        ProfileBackup.restoreIfAsked(root: root)

        #expect(read(root.appendingPathComponent("Library.json")) == "then")
        // The journal didn't come with the backup, so it no longer belongs.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("History.sqlite-wal").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Restore").path))
        // What was there is kept, so the restore can be undone.
        let before = try #require(ProfileBackup.all(in: root).first { $0.lastPathComponent.hasSuffix("before restore") })
        #expect(read(before.appendingPathComponent("Library.json")) == "now")
        #expect(read(before.appendingPathComponent("History.sqlite-wal")) == "journal")
        // Nothing staged is left lying around.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".restoring") }
        #expect(leftovers.isEmpty)
    }

    /// release.sh replaces the beta feed only once the stable version has caught up with its betas.
    @Test func versionComparisonIsNumeric() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/version-at-least.sh")
        func atLeast(_ a: String, _ b: String) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, a, b]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        #expect(try atLeast("0.5.0", "0.5.0"))
        #expect(try atLeast("0.10.0", "0.9.2"))
        #expect(try atLeast("0.5", "0.5.0"))
        #expect(try atLeast("1.0", "0.99.99"))
        #expect(try !atLeast("0.4.9", "0.5.0"))
        #expect(try !atLeast("0.5.0", "0.5.1"))
    }
}

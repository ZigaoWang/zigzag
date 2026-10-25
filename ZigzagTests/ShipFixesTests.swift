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

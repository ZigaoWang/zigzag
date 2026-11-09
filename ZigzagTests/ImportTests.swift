import Foundation
import Testing
import SQLite3
@testable import Zigzag

/// Known answers made outside Zigzag (Python's PBKDF2 and openssl), so these check Chromium's real scheme,
/// not just that our code agrees with itself.
struct ChromiumDecryptionTests {
    static let secret = Data("test-safe-storage".utf8)
    static let expectedKey = "a2b53d31770eef94e94ed19844dc81a6"
    static let ciphertext = "fe2d7ad3b89d89b78c3f5d1bf852fc72dea43804f5c1b5946dde430a212b45da"

    @Test func derivesChromiumsKey() {
        #expect(ChromiumImporter.deriveKey(Self.secret).hex == Self.expectedKey)
    }

    @Test func decryptsAV10Value() throws {
        let value = Data("v10".utf8) + Data(hex: Self.ciphertext)
        let password = try #require(ChromiumImporter.decrypt(value, key: ChromiumImporter.deriveKey(Self.secret)))
        #expect(password.matches(SecretString("zigzag-test-password")))
    }

    @Test func refusesTheWrongKeyAndOtherFormats() {
        let value = Data("v10".utf8) + Data(hex: Self.ciphertext)
        #expect(ChromiumImporter.decrypt(value, key: ChromiumImporter.deriveKey(Data("wrong".utf8)))?.matches(SecretString("zigzag-test-password")) != true)
        #expect(ChromiumImporter.decrypt(Data("v11".utf8) + Data(hex: Self.ciphertext), key: ChromiumImporter.deriveKey(Self.secret)) == nil)
    }

    /// A password file with one login that opens, one that won't, and a sign-in with no password: the one that
    /// won't is counted, so the import can say so instead of quietly bringing fewer.
    @Test func countsPasswordsThatWontOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Login Data")
        let good = "76313" + "0" + Self.ciphertext  // "v10" + the known ciphertext
        let bad = "763130" + String(repeating: "ab", count: 32)
        let sql = """
        CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, date_created INTEGER, date_password_modified INTEGER, blacklisted_by_user INTEGER);
        INSERT INTO logins VALUES ('https://example.com/login', 'a', X'\(good)', 0, 0, 0);
        INSERT INTO logins VALUES ('https://example.com/login', 'b', X'\(bad)', 0, 0, 0);
        INSERT INTO logins VALUES ('https://example.com/login', 'c', X'', 0, 0, 0);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [file.path, sql]
        try process.run()
        process.waitUntilExit()
        let read = ChromiumImporter.logins(at: file, key: ChromiumImporter.deriveKey(Self.secret))
        #expect(read.logins.map(\.username) == ["a"])
        #expect(read.unreadable == 1)
    }

    @Test func convertsChromiumTime() {
        // 2026-01-01 00:00:00 UTC in microseconds since 1601.
        let date = ChromiumImporter.date(13_411_699_200_000_000)
        #expect(date == ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        #expect(ChromiumImporter.date(0) == nil)
    }
}

private extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct CSVImportTests {
    func logins(_ text: String) throws -> (CSVImporter.Format, [ImportBatch.Login]) {
        guard case .success(let (format, batch)) = CSVImporter.parse(text) else { throw CSVImporter.Failure.unknownFormat }
        return (format, batch.logins)
    }

    @Test func readsApplePasswords() throws {
        let (format, logins) = try logins("Title,URL,Username,Password,Notes,OTPAuth\ngithub.com,https://github.com/,octo,p@ss,\"line one\nline two\",otpauth://totp/x\n")
        #expect(format == .applePasswords)
        #expect(logins.count == 1)
        #expect(logins[0].username == "octo")
        #expect(logins[0].password.matches(SecretString("p@ss")))
        #expect(logins[0].notes == "line one\nline two")
        #expect(logins[0].otpAuth == "otpauth://totp/x")
    }

    @Test func readsChromeWithQuotesAndCommas() throws {
        let (format, logins) = try logins("name,url,username,password,note\r\nExample,https://example.com,\"a, b\",\"he said \"\"hi\"\"\",\r\n")
        #expect(format == .chrome)
        #expect(logins[0].username == "a, b")
        #expect(logins[0].password.matches(SecretString("he said \"hi\"")))
    }

    /// Imported bookmarks keep their folders, nested as they were, and pages in the same folder share it.
    @Test func bookmarkFoldersComeOver() {
        let ids = (0..<4).map { _ in UUID() }
        let folders = Library.filed(ids, paths: [["Work"], ["Work", "Docs"], [], ["Work"]], into: [])
        #expect(folders.count == 2)
        let work = folders.first { $0.name == "Work" }, docs = folders.first { $0.name == "Docs" }
        #expect(work?.parentID == nil)
        #expect(docs?.parentID == work?.id)
        #expect(work?.bookmarkIDs == [ids[0], ids[3]])
        #expect(docs?.bookmarkIDs == [ids[1]])
        #expect(Library.filed([UUID()], paths: [["A", "B", "C", "D", "E", "F"]], into: []).count == 6)
    }

    /// Firefox's bookmarks come with their folders, its own roots left out.
    @Test func firefoxBookmarksKeepTheirFolders() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        sqlite3_exec(db, """
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
        INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________');
        INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 0, 'toolbar', 'toolbar_____');
        INSERT INTO moz_bookmarks VALUES (10, 2, NULL, 3, 0, 'Work', 'aaaaaaaaaaaa');
        INSERT INTO moz_bookmarks VALUES (11, 2, NULL, 10, 0, 'Docs', 'bbbbbbbbbbbb');
        INSERT INTO moz_places VALUES (1, 'https://a.test/'), (2, 'https://b.test/'), (3, 'https://c.test/');
        INSERT INTO moz_bookmarks VALUES (20, 1, 1, 3, 1, 'Top', 'cccccccccccc');
        INSERT INTO moz_bookmarks VALUES (21, 1, 2, 10, 1, 'In Work', 'dddddddddddd');
        INSERT INTO moz_bookmarks VALUES (22, 1, 3, 11, 0, 'In Docs', 'eeeeeeeeeeee');
        """, nil, nil, nil)
        sqlite3_close(db)
        let found = Dictionary(uniqueKeysWithValues: FirefoxImporter.bookmarks(at: file).map { ($0.title, $0.folders) })
        #expect(found["Top"] == [])
        #expect(found["In Work"] == ["Work"])
        #expect(found["In Docs"] == ["Work", "Docs"])
    }

    /// What Passwords › Export writes comes back whole, one-time codes included.
    @Test func readsZigzagsOwnExport() throws {
        let (format, logins) = try logins("name,url,username,password,note,otpauth\nGitHub,https://github.com,octo,p,,otpauth://totp/x\n")
        #expect(format == .chrome)
        #expect(logins[0].otpAuth == "otpauth://totp/x")
    }

    @Test func readsFirefoxBitwardenAndLastPass() throws {
        #expect(try logins("\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\",\"timeCreated\",\"timeLastUsed\",\"timePasswordChanged\"\n\"https://a.test\",\"u\",\"p\",,\"https://a.test\",\"{1}\",\"1\",\"1\",\"1\"").0 == .firefox)
        #expect(try logins("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,A,,,0,https://a.test,u,p,").0 == .bitwarden)
        #expect(try logins("url,username,password,totp,extra,name,grouping,fav\nhttps://a.test,u,p,,,A,,0").0 == .lastPass)
    }

    @Test func leavesOutRowsWithoutAWebsiteOrPassword() {
        guard case .success(let (_, batch)) = CSVImporter.parse("name,url,username,password\nA,https://a.test,u,p\nB,,u,p\nC,https://c.test,u,\n") else {
            Issue.record("didn't parse"); return
        }
        #expect(batch.logins.count == 1)
        #expect(batch.problems.count == 1)
    }

    @Test func refusesAnUnknownFile() {
        if case .success = CSVImporter.parse("a,b,c\n1,2,3") { Issue.record("should not parse") }
    }
}

/// Against a profile built outside Zigzag by scripts/make_firefox_fixture.py from NSS's formats.
struct FirefoxDecryptionTests {
    var profile: URL {
        get throws {
            let key4 = try #require(Bundle(for: FixtureMarker.self).url(forResource: "key4", withExtension: "db"))
            return key4.deletingLastPathComponent()
        }
    }

    @Test func unwrapsTheLoginKeyWithNoPrimaryPassword() throws {
        guard case .success(let key) = FirefoxImporter.key(in: try profile, primaryPassword: "") else { Issue.record("no key"); return }
        #expect(key == Data(100..<124))
    }

    @Test func decryptsALogin() throws {
        guard case .success(let key) = FirefoxImporter.key(in: try profile, primaryPassword: "") else { Issue.record("no key"); return }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: try profile.appendingPathComponent("logins.json"))) as? [String: Any]
        let login = try #require((json?["logins"] as? [[String: Any]])?.first)
        let user = try #require(FirefoxImporter.decryptField(login["encryptedUsername"] as! String, key: key))
        let password = try #require(FirefoxImporter.decryptField(login["encryptedPassword"] as! String, key: key))
        #expect(user.matches(SecretString("octocat")))
        #expect(password.matches(SecretString("zigzag-firefox-test")))
    }

    /// One primary password is typed for every profile; a profile without one still opens, whatever was typed.
    @Test func aProfileWithoutAPrimaryPasswordOpensWhateverWasTyped() throws {
        guard case .success(let key) = FirefoxImporter.key(in: try profile, primaryPassword: "another profile's") else {
            Issue.record("a profile with no primary password must open"); return
        }
        #expect(key == Data(100..<124))
    }
}

private final class FixtureMarker {}

struct SafariExportTests {
    @Test func decodesEntitiesInBookmarks() {
        #expect(SafariImporter.decodeEntities("Tom &amp; Jerry&#39;s &#x263A; &lt;b&gt;") == "Tom & Jerry's ☺ <b>")
        #expect(SafariImporter.decodeEntities("a?x=1&amp;y=2") == "a?x=1&y=2")
        #expect(SafariImporter.decodeEntities("R&D & more &bogus;") == "R&D & more &bogus;")
    }
}

/// Importing the same profile again: what its space already has stays once, and a space deleted since comes back.
struct ImportAgainTests {
    static let name = "From Chrome (A)"
    static let bookmarks = [ImportBatch.Bookmark(url: URL(string: "https://example.com/")!, title: "Example"),
                            ImportBatch.Bookmark(url: URL(string: "https://example.org/")!, title: "Example Org", folders: ["Work"])]
    static let personal = SpaceInfo(name: "Personal", color: .sky)

    /// The space as an import of `bookmarks` leaves it.
    static func imported(_ new: [ImportBatch.Bookmark]) -> SpaceInfo {
        var space = SpaceInfo(name: name, color: .mint)
        space.bookmarks = new.map { Bookmark(url: $0.url, title: $0.title) }
        return space
    }

    @Test func aDeletedSpaceComesBackWithItsPages() {
        let first = ImportCoordinator.merged(Self.bookmarks, into: [Self.personal], named: Self.name)
        #expect(first.space == nil)
        #expect(first.new.count == 2)
        // Deleted: only Personal is left, so all of it is new again, its folder too.
        let space = Self.imported(first.new)
        let again = ImportCoordinator.merged(Self.bookmarks, into: [Self.personal, space].filter { $0.id != space.id }, named: Self.name)
        #expect(again.space == nil)
        #expect(again.new.map(\.title) == ["Example", "Example Org"])
        #expect(again.new.last?.folders == ["Work"])
    }

    @Test func importingTwiceAddsNothingTwice() {
        let space = Self.imported(ImportCoordinator.merged(Self.bookmarks, into: [Self.personal], named: Self.name).new)
        let same = ImportBatch.Bookmark(url: URL(string: "http://www.example.com")!, title: "Same page")
        let again = ImportCoordinator.merged(Self.bookmarks + [same], into: [Self.personal, space], named: Self.name)
        #expect(again.space?.id == space.id)
        #expect(again.new.isEmpty)
    }

    /// A finished Import window asked for again starts over, so importing again really imports.
    @Test func aFinishedImportWindowStartsOver() {
        #expect(ImportWindowController.startsOver(.done))
        #expect(!ImportWindowController.startsOver(.choose))
        #expect(!ImportWindowController.startsOver(.importing))
        #expect(!ImportWindowController.startsOver(nil))
    }
}

import Foundation
import CryptoKit
import Testing
@testable import Zigzag

struct AddonsMozillaPageTests {
    /// The listing's slug in an AMO page address, with or without the locale prefix and a trailing path.
    @Test func theListingIsReadFromAnAMOPage() {
        let slug = ExtensionStore.addonsSlug(from:)
        #expect(slug(URL(string: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/")!) == "ublock-origin")
        #expect(slug(URL(string: "https://addons.mozilla.org/firefox/addon/darkreader")!) == "darkreader")
        #expect(slug(URL(string: "https://addons.mozilla.org/en-US/firefox/addon/darkreader/reviews/")!) == "darkreader")
        // Only this store, only a listing, and never a slug that could be a path.
        #expect(slug(URL(string: "https://example.com/firefox/addon/ublock-origin/")!) == nil)
        #expect(slug(URL(string: "https://addons.mozilla.org/en-US/firefox/")!) == nil)
        #expect(slug(URL(string: "https://addons.mozilla.org/en-US/firefox/addon/")!) == nil)
        #expect(slug(URL(string: "https://addons.mozilla.org/en-US/firefox/addon/..%2F..%2Fetc/")!) == nil)
        #expect(slug(nil) == nil)
        // A lookalike host is not the store, and neither is its API host.
        #expect(ExtensionStore.addonsHost("addons.mozilla.org"))
        #expect(!ExtensionStore.addonsHost("services.addons.mozilla.org"))
        #expect(!ExtensionStore.addonsHost("addons.mozilla.org.evil.example"))
    }

    /// The file half of the boundary: only AMO's own download path hands over a package. A page there can point a
    /// button anywhere, and another host's copy of the path is not the store.
    @Test func onlyTheStoresOwnDownloadPathIsAPackage() {
        let file = ExtensionStore.isAddonsFile
        #expect(file(URL(string: "https://addons.mozilla.org/firefox/downloads/file/4242/ublock_origin-1.60.0.xpi")!))
        #expect(file(URL(string: "https://addons.mozilla.org/en-US/firefox/downloads/file/1/addon.xpi")!))
        #expect(!file(URL(string: "https://example.com/firefox/downloads/file/1/addon.xpi")!))
        #expect(!file(URL(string: "https://addons.mozilla.org/firefox/addon/ublock-origin/")!))
        #expect(!file(URL(string: "http://addons.mozilla.org/firefox/downloads/file/1/addon.xpi")!))
        #expect(!file(URL(string: "https://addons.mozilla.org.evil.example/firefox/downloads/file/1/addon.xpi")!))
        #expect(!file(nil))
    }

    /// The store's pages are asked for as Firefox, so its button is Add to Firefox; nowhere else is.
    @Test func theStorePagesAreAskedAsFirefox() {
        let page = Tab.addonsPage
        #expect(page(URL(string: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/")!) != nil)
        #expect(page(URL(string: "https://addons.mozilla.org/firefox/addon/darkreader")!) != nil)
        #expect(page(URL(string: "https://example.com/firefox/addon/ublock-origin/")!) == nil)
        #expect(page(URL(string: "http://addons.mozilla.org/firefox/addon/ublock-origin/")!) == nil)
        #expect(page(URL(string: "https://addons.mozilla.org.evil.example/firefox/addon/x/")!) == nil)
    }

    /// AMO publishes each file's sha256; a package whose bytes don't match it is refused, not installed.
    @Test func anAMOPackageMustMatchTheHashTheStorePublishes() {
        let bytes = Data("an xpi's bytes".utf8)
        let good = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(ExtensionStore.matchesPublishedHash(bytes, sha256: good))
        #expect(ExtensionStore.matchesPublishedHash(bytes, sha256: good.uppercased()))
        // As AMO's API writes it; another algorithm's prefix is not taken.
        #expect(ExtensionStore.matchesPublishedHash(bytes, sha256: "sha256:" + good))
        #expect(!ExtensionStore.matchesPublishedHash(bytes, sha256: "sha1:" + good))
        // A different file, a truncated hash, an empty one, none at all, and one with something appended: refused.
        #expect(!ExtensionStore.matchesPublishedHash(Data("other bytes".utf8), sha256: good))
        #expect(!ExtensionStore.matchesPublishedHash(bytes, sha256: String(good.prefix(63))))
        #expect(!ExtensionStore.matchesPublishedHash(bytes, sha256: ""))
        #expect(!ExtensionStore.matchesPublishedHash(bytes, sha256: nil))
        #expect(!ExtensionStore.matchesPublishedHash(bytes, sha256: good + "00"))
    }

    /// The API's current file counts only when it names an AMO file address and a hash.
    @Test func theAPIsCurrentFileIsRead() {
        let good = Data(#"{"current_version":{"file":{"url":"https://addons.mozilla.org/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi","hash":"sha256:66d0e3f21ce3b32b1bc0a9399b93cb2c9aa598ef18805d92118c76f66e266c1e"}}}"#.utf8)
        let file = ExtensionStore.publishedAddonsFile(fromAPI: good)
        #expect(file?.url.path == "/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi")
        #expect(file?.hash.hasPrefix("sha256:") == true)
        let elsewhere = Data(#"{"current_version":{"file":{"url":"https://example.com/firefox/downloads/file/1/x.xpi","hash":"sha256:00"}}}"#.utf8)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: elsewhere) == nil)
        let noHash = Data(#"{"current_version":{"file":{"url":"https://addons.mozilla.org/firefox/downloads/file/1/x.xpi"}}}"#.utf8)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: noHash) == nil)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: Data("not json".utf8)) == nil)
    }

    /// The API's guid comes with the file when it reads as an ID.
    @Test func theAPIsGUIDIsRead() {
        func answer(_ guid: String) -> Data {
            Data(("{\"guid\":\"" + guid + "\",\"current_version\":{\"file\":{\"url\":\"https://addons.mozilla.org/firefox/downloads/file/1/x.xpi\",\"hash\":\"sha256:00\"}}}").utf8)
        }
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: answer("uBlock0@raymondhill.net"))?.guid == "uBlock0@raymondhill.net")
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: answer("{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"))?.guid == "{ec8030f7-c20a-464f-9b0e-13a3a9e97384}")
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: answer(""))?.guid == nil)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: answer("a/b"))?.guid == nil)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: answer(String(repeating: "a", count: 256)))?.guid == nil)
    }

    /// Only the exact file the API names goes to the install sheet: same AMO host and path.
    @Test func onlyThePublishedFileIsInstalled() {
        let published = URL(string: "https://addons.mozilla.org/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi")!
        let match = ExtensionStore.isPublishedAddonsFile
        #expect(match(published, published))
        #expect(match(URL(string: "https://addons.mozilla.org/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi?src=dp-btn-primary")!, published))
        #expect(!match(URL(string: "https://addons.mozilla.org/firefox/downloads/file/5257480/ublock_origin-1.76.3.xpi")!, published))
        #expect(!match(URL(string: "https://addons.cdn.mozilla.net/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi")!, published))
        #expect(!match(URL(string: "http://addons.mozilla.org/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi")!, published))
        #expect(!match(nil, published))
    }

    /// The API request never follows a redirect.
    @Test func theAPIRequestRefusesRedirects() {
        let response = HTTPURLResponse(url: URL(string: "https://addons.mozilla.org/api/v5/addons/addon/x/")!, statusCode: 302,
                                       httpVersion: nil, headerFields: ["Location": "https://example.com/"])!
        var followed: URLRequest? = URLRequest(url: URL(string: "https://example.com/")!)
        ExtensionStore.NoRedirects().urlSession(.shared, task: URLSession.shared.dataTask(with: response.url!),
                                                willPerformHTTPRedirection: response,
                                                newRequest: URLRequest(url: URL(string: "https://example.com/")!)) { followed = $0 }
        #expect(followed == nil)
        #expect(ExtensionStore.addonsAPIURL(slug: "ublock-origin")?.host() == "addons.mozilla.org")
        #expect(ExtensionStore.addonsAPIURL(slug: "ublock-origin")?.scheme == "https")
    }

    // MARK: A click on Add to Firefox, from click to install sheet (#429)

    private static let file = URL(string: "https://addons.mozilla.org/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi")!
    private static let listing = URL(string: "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/")!
    private static let api = Data(#"{"guid":"uBlock0@raymondhill.net","current_version":{"file":{"url":"https://addons.mozilla.org/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi","hash":"sha256:66d0e3f21ce3b32b1bc0a9399b93cb2c9aa598ef18805d92118c76f66e266c1e"}}}"#.utf8)

    /// The listing is read from the page the click was made on: by the time the file starts saving, the tab's own
    /// address can be the file's (mid-navigation), which names no listing and sent the file to Downloads.
    @Test func theClickIsReadFromThePageItWasMadeOn() {
        let click = ExtensionStore.AddonsClick(target: Self.file, page: Self.listing, userInitiated: true)
        #expect(click?.slug == "ublock-origin")
        #expect(ExtensionStore.AddonsClick(target: Self.file, page: URL(string: "https://addons.mozilla.org/firefox/addon/ublock-origin/versions/"), userInitiated: true)?.slug == "ublock-origin")
        // The address the tab shows mid-navigation: no listing in it.
        #expect(ExtensionStore.addonsSlug(from: Self.file) == nil)
        #expect(ExtensionStore.AddonsClick(target: Self.file, page: Self.file, userInitiated: true) == nil)
        // Not a click, not the store's file, not from the store.
        #expect(ExtensionStore.AddonsClick(target: Self.file, page: Self.listing, userInitiated: false) == nil)
        #expect(ExtensionStore.AddonsClick(target: Self.listing, page: Self.listing, userInitiated: true) == nil)
        #expect(ExtensionStore.AddonsClick(target: URL(string: "https://example.com/firefox/downloads/file/1/x.xpi"), page: Self.listing, userInitiated: true) == nil)
        #expect(ExtensionStore.AddonsClick(target: Self.file, page: URL(string: "https://example.com/firefox/addon/ublock-origin/"), userInitiated: true) == nil)
    }

    /// The click lasts through its own file (a redirect, a query), and nothing else.
    @Test func theClickCoversItsOwnFileOnly() throws {
        let click = try #require(ExtensionStore.AddonsClick(target: Self.file, page: Self.listing, userInitiated: true))
        #expect(click.covers(Self.file))
        #expect(click.covers(URL(string: Self.file.absoluteString + "?src=dp-btn-primary")))
        #expect(!click.covers(URL(string: "https://addons.mozilla.org/firefox/downloads/file/5257480/ublock_origin-1.76.3.xpi")))
        #expect(!click.covers(URL(string: "https://example.com/firefox/downloads/file/5257481/ublock_origin-1.76.4.xpi")))
        #expect(!click.covers(Self.listing))
        #expect(!click.covers(nil))
    }

    /// The API's answer decides: its current file installs, another file is a download, no answer is a notice.
    @Test func theAPIsAnswerDecidesWhatTheFileBecomes() throws {
        let published = try #require(ExtensionStore.publishedAddonsFile(fromAPI: Self.api))
        #expect(ExtensionStore.addonsInstall(file: Self.file, published: published) == .install(published))
        #expect(ExtensionStore.addonsInstall(file: URL(string: "https://addons.mozilla.org/firefox/downloads/file/5250345/ublock_origin-1.76.2.xpi"), published: published) == .notCurrent)
        #expect(ExtensionStore.addonsInstall(file: Self.file, published: nil) == .unreachable)
    }

    /// One failed ask of the API used to send the file to Downloads; it's asked once more.
    @Test func theAPIIsAskedAgainOnce() async {
        let ok = HTTPURLResponse(url: ExtensionStore.addonsAPIURL(slug: "ublock-origin")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let busy = HTTPURLResponse(url: ok.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        let asked = Counter()
        let second = await ExtensionStore.publishedAddonsFile(slug: "ublock-origin") { _ in
            await asked.add() == 1 ? (Data(), busy as URLResponse) : (Self.api, ok as URLResponse)
        }
        #expect(second?.url.path == Self.file.path)
        #expect(await asked.count == 2)
        let never = Counter()
        #expect(await ExtensionStore.publishedAddonsFile(slug: "ublock-origin") { _ in await never.add(); return nil } == nil)
        #expect(await never.count == 2)
    }

    /// A checked click skips the download question (#428); a kept Block for the site still stops it.
    @Test func aCheckedClickAsksOnlyInTheInstallSheet() {
        #expect(Tab.skipsDownloadQuestion(kept: nil))
        #expect(Tab.skipsDownloadQuestion(kept: true))
        #expect(!Tab.skipsDownloadQuestion(kept: false))
    }

    @Test func onlyA200FromAMOCounts() {
        let url = ExtensionStore.addonsAPIURL(slug: "ublock-origin")!
        let answer = { (status: Int, at: URL) in HTTPURLResponse(url: at, statusCode: status, httpVersion: nil, headerFields: nil)! }
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: Self.api, response: answer(200, url)) != nil)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: Self.api, response: answer(403, url)) == nil)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: Self.api, response: answer(200, URL(string: "https://example.com/api/")!)) == nil)
        #expect(ExtensionStore.publishedAddonsFile(fromAPI: Self.api, response: answer(200, URL(string: "http://addons.mozilla.org/api/")!)) == nil)
    }
}

private actor Counter {
    private(set) var count = 0
    @discardableResult func add() -> Int { count += 1; return count }
}

/// An XPI made byte by byte: stored entries, then the central index and its end record. Shared by every test that
/// needs one — `FirefoxInstallTests` and `XPIPackageTests` — so
/// there is one zip writer, not a copy per file. The local gate compiles the requested suites together (and CI
/// compiles the whole target), so a declaration here reaches the other suites.
///
/// Kept in this file rather than a file of its own: the local gate copies only the files that declare a suite it was
/// asked for, so a standalone fixture file would not be compiled. (Reported to the reviewer.)
nonisolated struct XPIArchive {
    struct Entry {
        var name: String
        var data = Data()
        var mode: UInt32 = 0o100644
    }

    var entries: [Entry]

    var data: Data {
        var archive = Data(), index = Data()
        func u16(_ value: UInt16, into bytes: inout Data) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32, into bytes: inout Data) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        for entry in entries {
            let name = Data(entry.name.utf8), crc = PackageZip.crc32([UInt8](entry.data)), offset = UInt32(archive.count)
            u32(0x0403_4B50, into: &archive); u16(20, into: &archive); u16(0, into: &archive); u16(0, into: &archive)
            u16(0, into: &archive); u16(0, into: &archive); u32(crc, into: &archive)
            u32(UInt32(entry.data.count), into: &archive); u32(UInt32(entry.data.count), into: &archive)
            u16(UInt16(name.count), into: &archive); u16(0, into: &archive); archive.append(name); archive.append(entry.data)
            u32(0x0201_4B50, into: &index); u16(0x0314, into: &index); u16(20, into: &index); u16(0, into: &index)
            u16(0, into: &index); u16(0, into: &index); u16(0, into: &index); u32(crc, into: &index)
            u32(UInt32(entry.data.count), into: &index); u32(UInt32(entry.data.count), into: &index)
            u16(UInt16(name.count), into: &index); u16(0, into: &index); u16(0, into: &index)
            u16(0, into: &index); u16(0, into: &index); u32(entry.mode << 16, into: &index); u32(offset, into: &index)
            index.append(name)
        }
        let start = UInt32(archive.count)
        archive.append(index)
        u32(0x0605_4B50, into: &archive); u16(0, into: &archive); u16(0, into: &archive)
        u16(UInt16(entries.count), into: &archive); u16(UInt16(entries.count), into: &archive)
        u32(UInt32(index.count), into: &archive); u32(start, into: &archive); u16(0, into: &archive)
        return archive
    }

    static func json(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    /// An XPI whose root manifest is `manifest`, with any of its files beside it.
    static func xpi(_ manifest: [String: Any], files: [String: Data] = [:]) throws -> Data {
        var entries = [Entry(name: "manifest.json", data: try json(manifest))]
        for (name, data) in files.sorted(by: { $0.key < $1.key }) { entries.append(.init(name: name, data: data)) }
        return XPIArchive(entries: entries).data
    }

    /// An XPI whose manifest is the bytes given: for a manifest WebKit can't read, whatever JSON sees in it.
    static func xpi(manifestData: Data) -> Data {
        XPIArchive(entries: [.init(name: "manifest.json", data: manifestData)]).data
    }

    /// A Firefox manifest, with whatever else the test needs.
    static func manifest(_ geckoID: String?, _ version: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = ["manifest_version": 2, "name": "Test", "version": version]
        if let geckoID { fields["browser_specific_settings"] = ["gecko": ["id": geckoID]] }
        for (key, value) in extra { fields[key] = value }
        return fields
    }
}

/// Installing a Firefox package (.xpi): it gets a record of its own — its kind, its gecko ID and the opaque ID it
/// installs as — the package is unpacked as a Chrome one is, and its manifest is made into the shape WebKit loads
/// before anything is handed over.
@MainActor
@Suite(.serialized)
struct FirefoxInstallTests {
    // MARK: The store the tests work in

    /// A store of its own: the packages go in a temporary folder and the profile is one no list knows, so nothing
    /// an install writes lands in the person's own Extensions folder or Library.
    private final class Workspace {
        let folder: URL
        let root: URL
        let profile: Profile

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("zigzag-firefox-install-\(UUID().uuidString)")
            root = folder.appendingPathComponent("Extensions", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            profile = Profile(id: UUID())
            ExtensionStore.rootOverride = root
            ExtensionStore.forgetWhatWasRead()
        }

        /// An .xpi written where the test can hand it to the store.
        func xpiFile(_ data: Data) throws -> URL {
            let url = folder.appendingPathComponent("\(UUID().uuidString).xpi")
            try data.write(to: url)
            return url
        }

        func record(_ id: String) -> ExtensionStore.Package? { ExtensionStore.package(id) }

        func cleanUp() {
            ExtensionStore.rootOverride = nil
            ExtensionStore.forgetWhatWasRead()
            try? FileManager.default.removeItem(at: folder)
            // The profile isn't one any list knows: its own folder is this test's, and goes with it.
            try? FileManager.default.removeItem(at: profile.folder)
        }
    }

    // MARK: Fixtures

    private static func xpi(_ manifest: [String: Any], files: [String: Data] = [:]) throws -> Data {
        try XPIArchive.xpi(manifest, files: files)
    }

    private static func xpi(manifestData: Data) -> Data { XPIArchive.xpi(manifestData: manifestData) }

    private static func manifest(_ geckoID: String?, _ version: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        XPIArchive.manifest(geckoID, version, extra)
    }

    private static func installed(_ result: Result<String, ExtensionStore.InstallError>) throws -> String {
        switch result {
        case .success(let name): return name
        case .failure(let error): throw error
        }
    }

    /// Installs an `.xpi` through the store's own two steps, as every caller does: prepare, then finish once the
    /// review sheet is confirmed (`ExtensionSheet.offer` in the app). A test convenience, so the store keeps one
    /// install path and none of its own installs past the sheet.
    private static func install(at url: URL, in profile: Profile) async -> Result<String, ExtensionStore.InstallError> {
        switch await ExtensionStore.prepareInstallXPI(at: url) {
        case .success(let prepared): return await ExtensionStore.finishInstall(prepared, in: profile)
        case .failure(let error): return .failure(error)
        }
    }

    /// The staging folders an install makes while it works: none should outlive the call.
    private static func stagingFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("zigzag-xpi-") })
    }

    // MARK: Tests

    /// Bytes already checked are prepared as they are, never read again from disk.
    @Test func checkedBytesArePreparedAsTheyAre() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let bytes = try Self.xpi(Self.manifest("bytes@example.com", "1.0"))
        guard case .success(let prepared) = await ExtensionStore.prepareInstallXPI(data: bytes) else {
            Issue.record("bytes didn't prepare")
            return
        }
        #expect(prepared.kind == .firefox)
        #expect(prepared.firefoxID == "bytes@example.com")
        ExtensionStore.discard(prepared)
    }

    @Test func installingAnXPIRecordsItsKindGeckoIDAndOpaqueID() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("one@example.com", "1.2.3")))
        let name = try Self.installed(await Self.install(at: url, in: work.profile))
        #expect(name == "Test")

        let id = ExtensionStore.xpiID(forGeckoID: "one@example.com", data: Data())
        // Chrome's own alphabet, the shape the rest of the store assumes.
        #expect(id.count == 32)
        #expect(id.allSatisfy { ("a"..."p").contains($0) })
        #expect(ExtensionStore.isExtensionID(id))
        let record = try #require(work.record(id))
        #expect(record.kind == "firefox")
        #expect(record.firefoxID == "one@example.com")
        #expect(record.version == "1.2.3")
        #expect(try #require(work.profile.installs.state(id)).enabled)
    }

    @Test func twoXPIsWithTheSameGeckoIDAreOneRecordAndTheVersionIsReplaced() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        _ = try Self.installed(await Self.install(at: try work.xpiFile(try Self.xpi(Self.manifest("same@example.com", "1.0"))), in: work.profile))
        _ = try Self.installed(await Self.install(at: try work.xpiFile(try Self.xpi(Self.manifest("same@example.com", "2.0"))), in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "same@example.com", data: Data())
        #expect(ExtensionStore.packageIDs == [id])
        #expect(work.record(id)?.version == "2.0")
        let versions = try FileManager.default.contentsOfDirectory(atPath: work.root.appendingPathComponent(id).appendingPathComponent("versions").path)
        #expect(versions == ["2.0"])
    }

    @Test func aRecordWrittenWithoutAKindReadsAsChromium() throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let folder = work.root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":"9.9","unpackedPath":"/somewhere/else"}"#.utf8).write(to: folder.appendingPathComponent("state.json"))
        let record = try #require(work.record(id))
        #expect(record.kind == "chromium")
        #expect(record.firefoxID == nil)
        #expect(record.version == "9.9")
        #expect(record.unpackedPath == "/somewhere/else")

        // A Firefox record keeps both its own way.
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", kind: "firefox", firefoxID: "a@b"), for: id)
        let saved = try #require(work.record(id))
        #expect(saved.kind == "firefox" && saved.firefoxID == "a@b")
    }

    /// An MV3 Firefox manifest keeps host patterns in `permissions` and its policy as one string: exactly what
    /// normalization exists to rescue. It installs, and the copy on disk is the normalized one.
    @Test func anMV3XPIWithHostsInPermissionsAndAStringPolicyInstallsNormalized() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("hosts@example.com", "2.0", [
            "manifest_version": 3,
            "permissions": ["storage", "https://example.com/*"],
            "optional_permissions": ["*://*.other.test/*"],
            "content_security_policy": "script-src 'self'; object-src 'self'",
        ])))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "hosts@example.com", data: Data())
        let folder = try #require(ExtensionStore.packageDirectory(for: id))
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        // The host patterns moved where WebKit reads site access; the API permission stayed where it was.
        #expect(onDisk["permissions"] as? [String] == ["storage"])
        #expect(onDisk["host_permissions"] as? [String] == ["https://example.com/*"])
        #expect(onDisk["optional_permissions"] as? [String] == [])
        #expect(onDisk["optional_host_permissions"] as? [String] == ["*://*.other.test/*"])
        // Firefox's one-string policy became the shape WebKit expects.
        let policy = try #require(onDisk["content_security_policy"] as? [String: Any])
        #expect(policy["extension_pages"] as? String == "script-src 'self'; object-src 'self'")
    }

    /// A package's own manifest can be one WebKit can't read as it came (not UTF-8); the normalized copy we write is
    /// what WebKit loads, so it installs. Verifying before normalization would have refused it.
    @Test func aManifestWebKitCannotReadAsItCameIsRescuedByNormalization() async throws {
        let manifestData = try #require(#"{"manifest_version":2,"name":"Rescued","version":"1.0","browser_specific_settings":{"gecko":{"id":"rescued@example.com"}}}"#.data(using: .utf16LittleEndian))
        let xpi = Self.xpi(manifestData: manifestData)
        // The package itself is sound: its manifest is JSON, just not in an encoding WebKit reads.
        #expect(try XPIPackage(xpi).manifest["name"] as? String == "Rescued")
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(xpi)
        let name = try Self.installed(await Self.install(at: url, in: work.profile))
        #expect(name == "Rescued")
        let id = ExtensionStore.xpiID(forGeckoID: "rescued@example.com", data: Data())
        #expect(work.record(id)?.kind == "firefox")
    }

    /// A manifest version WebKit doesn't run: its parser takes the manifest, but nothing here implements it, so the
    /// package is refused and nothing is left staged.
    @Test func anXPIWhoseManifestWebKitCannotRunFailsUnsupportedAndLeavesNoStaging() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("future@example.com", "1.0", ["manifest_version": 5])))

        let before = Self.stagingFolders()
        let result = await ExtensionStore.prepareInstallXPI(at: url)
        guard case .failure(let error) = result, case .unsupported = error else {
            Issue.record("expected .unsupported, got \(result)")
            return
        }
        #expect(Self.stagingFolders() == before)
    }

    /// A theme isn't an extension: Zigzag draws its own look, so a theme-only package is refused before the review
    /// sheet, from either store or a folder, and leaves nothing staged. One that also runs something installs (#454).
    @Test func aThemeOnlyPackageIsRefusedAndAnExtensionWithAThemeInstalls() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let colors: [String: Any] = ["colors": ["frame": "#000000", "tab_background_text": "#ffffff"]]
        #expect(ExtensionStore.isThemeOnly(["manifest_version": 3, "name": "Dark", "version": "1.0", "theme": colors]))
        #expect(ExtensionStore.isThemeOnly(["manifest_version": 2, "name": "Dark", "version": "1.0", "theme_experiment": ["stylesheet": "a.css"]]))
        #expect(!ExtensionStore.isThemeOnly(["manifest_version": 3, "name": "Both", "version": "1.0", "theme": colors,
                                             "content_scripts": [["matches": ["<all_urls>"], "js": ["a.js"]]]]))
        #expect(!ExtensionStore.isThemeOnly(["manifest_version": 3, "name": "Plain", "version": "1.0", "action": [String: Any]()]))

        let theme = try work.xpiFile(try Self.xpi(Self.manifest("theme@example.com", "2.0", ["theme": colors])))
        let before = Self.stagingFolders()
        let refused = await ExtensionStore.prepareInstallXPI(at: theme)
        guard case .failure(let error) = refused, case .theme = error else {
            Issue.record("expected .theme, got \(refused)")
            return
        }
        #expect(Self.stagingFolders() == before)

        let both = try work.xpiFile(try Self.xpi(Self.manifest("both@example.com", "1.0", ["theme": colors, "background": ["scripts": ["bg.js"]]]),
                                                 files: ["bg.js": Data("void 0;".utf8)]))
        guard case .success(let prepared) = await ExtensionStore.prepareInstallXPI(at: both) else {
            Issue.record("an extension with a theme should prepare")
            return
        }
        ExtensionStore.discard(prepared)

        let folder = work.folder.appendingPathComponent("theme-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Dark", "version": "1.0", "theme": colors])
            .write(to: folder.appendingPathComponent("manifest.json"))
        #expect(ExtensionStore.folderIsThemeOnly(folder))
    }

    /// Firefox versions may carry letters (`1.0.0b1`), which Chrome's grammar refuses. A package isn't damaged over
    /// one: it installs, and the version it declares is the one recorded.
    @Test func aFirefoxVersionWithLettersInstallsAndIsRecorded() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("letters@example.com", "1.0.0b1")))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "letters@example.com", data: Data())
        #expect(work.record(id)?.version == "1.0.0b1")
        let versions = try FileManager.default.contentsOfDirectory(atPath: work.root.appendingPathComponent(id).appendingPathComponent("versions").path)
        #expect(versions == ["1.0.0b1"])
    }

    /// A Firefox version names the folder it's kept in, so it still has to be a safe name: no separators, no
    /// climbing out, not empty, not enormous.
    @Test func aFirefoxVersionMustStillBeASafeFolderName() {
        for good in ["1.0", "1.0.0b1", "2024.1-beta", "3.0.0.0", "1.2.3+build"] {
            #expect(ExtensionStore.isValidFirefoxVersion(good), "\(good)")
        }
        for bad in ["", ".", "..", "a/b", "a\\b", "a..b", ".hidden", "a b", String(repeating: "1", count: 65)] {
            #expect(!ExtensionStore.isValidFirefoxVersion(bad), "\(bad)")
        }
    }

    @Test func aPreparedXPIReportsItsKindAndID() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("prepared@example.com", "1.0")))
        let result = await ExtensionStore.prepareInstallXPI(at: url)
        guard case .success(let prepared) = result else {
            Issue.record("expected a prepared install, got \(result)")
            return
        }
        defer { ExtensionStore.discard(prepared) }
        #expect(prepared.kind == .firefox)
        #expect(prepared.firefoxID == "prepared@example.com")
        #expect(ExtensionStore.isExtensionID(prepared.id))
        #expect(prepared.version == "1.0")
    }

    /// A Chrome package's prepared install is a Chrome one, as every caller before this task already assumed.
    @Test func aChromeRecordStillReadsAsChromium() throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let id = "abcdefghijklmnopabcdefghijklmnop"
        ExtensionStore.save(ExtensionStore.Package(version: "1.0"), for: id)
        #expect(work.record(id)?.kind == "chromium")
        #expect(work.record(id)?.firefoxID == nil)
    }

    /// Only the store's own packages are asked about updates: a Firefox package came from a file, and an unpacked one
    /// is the person's folder. Asking Google for either would be a request it can't answer.
    @Test func onlyTheStoresOwnPackagesAreAskedForUpdates() throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let chrome = "abcdefghijklmnopabcdefghijklmnop"
        let firefox = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let unpacked = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ExtensionStore.save(ExtensionStore.Package(version: "1.0"), for: chrome)
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", kind: "firefox", firefoxID: "one@example.com"), for: firefox)
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", unpackedPath: work.folder.path), for: unpacked)

        #expect(ExtensionStore.updateCandidates([chrome, firefox, unpacked]) == [chrome])
    }

    /// No gecko ID: the package is named by its bytes, so the same file at two paths is one record.
    @Test func anXPIWithNoGeckoIDIsNamedByItsBytesSoTheSameFileAtTwoPathsIsOneRecord() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let bytes = try Self.xpi(Self.manifest(nil, "1.0"))
        _ = try Self.installed(await Self.install(at: try work.xpiFile(bytes), in: work.profile))
        _ = try Self.installed(await Self.install(at: try work.xpiFile(bytes), in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: nil, data: bytes)
        #expect(ExtensionStore.packageIDs == [id])
        #expect(work.record(id)?.firefoxID == nil)
        #expect(SettingsView.packageKindDetail(id) == ["Firefox"])
    }

    /// From Add to Firefox, a package with no gecko ID is named by AMO's guid: two versions are one record.
    @Test func twoVersionsFromTheStoreWithNoGeckoIDAreOneRecord() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        for version in ["1.0", "1.1"] {
            let bytes = try Self.xpi(Self.manifest(nil, version))
            guard case .success(let prepared) = await ExtensionStore.prepareInstallXPI(data: bytes, storeID: "store@example.com") else {
                Issue.record("\(version) didn't prepare")
                return
            }
            _ = try Self.installed(await ExtensionStore.finishInstall(prepared, in: work.profile))
        }
        let id = ExtensionStore.xpiID(forGeckoID: "store@example.com", data: Data())
        #expect(ExtensionStore.packageIDs == [id])
        #expect(work.record(id)?.version == "1.1")
        // A guid that doesn't read as one isn't used: the bytes name it, as from a file.
        let bytes = try Self.xpi(Self.manifest(nil, "2.0"))
        guard case .success(let odd) = await ExtensionStore.prepareInstallXPI(data: bytes, storeID: "../x") else {
            Issue.record("odd guid didn't prepare")
            return
        }
        #expect(odd.id == ExtensionStore.xpiID(forGeckoID: nil, data: bytes))
        ExtensionStore.discard(odd)
    }

    /// A signature file in the package changes nothing Zigzag says: its presence isn't a check that the signature is
    /// valid, so Settings says only that this is a Firefox extension, and records the package the same way.
    @Test func aSignatureFileChangesNothingZigzagSays() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let bytes = XPIArchive(entries: [
            .init(name: "manifest.json", data: try XPIArchive.json(Self.manifest("signed@example.com", "1.0"))),
            .init(name: "META-INF/mozilla.rsa", data: Data("signature".utf8)),
        ]).data
        _ = try Self.installed(await Self.install(at: try work.xpiFile(bytes), in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "signed@example.com", data: Data())
        #expect(work.record(id)?.kind == "firefox")
        #expect(SettingsView.packageKindDetail(id) == ["Firefox"])
    }

    /// The manifest Zigzag stores is the normalized copy, and it still carries Mozilla's keys, so the gecko ID and
    /// Firefox's own fields stay readable; the polyfill's gate is the record's kind, not these keys.
    @Test func theInstalledManifestKeepsMozillasKeys() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let url = try work.xpiFile(try Self.xpi(Self.manifest("keys@example.com", "1.0", ["background": ["scripts": ["a.js"]]])))
        _ = try Self.installed(await Self.install(at: url, in: work.profile))

        let id = ExtensionStore.xpiID(forGeckoID: "keys@example.com", data: Data())
        let folder = try #require(ExtensionStore.packageDirectory(for: id))
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(FirefoxManifest.isFirefox(onDisk))
        #expect((onDisk["browser_specific_settings"] as? [String: Any])?["gecko"] != nil)
    }

    /// A folder carrying Firefox's own keys is still recorded as Chrome's: the manifest doesn't decide the kind.
    /// The person's own folder is left exactly as it is, never normalized.
    @Test func aFolderWithFirefoxKeysStaysChromeAndIsLeftAsItIs() async throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let folder = work.folder.appendingPathComponent("firefox-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = Self.manifest("folder@example.com", "1.0", ["permissions": ["contextualIdentities"]])
        manifest["sidebar_action"] = ["default_panel": "panel.html"]
        try XPIArchive.json(manifest).write(to: folder.appendingPathComponent("manifest.json"))

        let record = ExtensionStore.unpackedPackage(for: folder)
        #expect(record.kind == "chromium")
        #expect(record.firefoxID == nil)
        #expect(record.unpackedPath == folder.standardizedFileURL.path)
        // The sheet reads the same shipped overlay as any package; a permission only Firefox knows is reported by
        // its own name, since WebKit doesn't supply it and no claim words it.
        let reviewed = try #require(await ExtensionStore.reviewUnpacked(folder))
        #expect(reviewed.report.limits.map(\.text).contains("contextualIdentities"))
        // Nothing was written back: no normalized side_panel twin in the person's own folder.
        let onDisk = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(onDisk["side_panel"] == nil)

        let chromeFolder = work.folder.appendingPathComponent("chrome-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: chromeFolder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":2,"name":"Chrome","version":"1.0"}"#.utf8).write(to: chromeFolder.appendingPathComponent("manifest.json"))
        let chrome = ExtensionStore.unpackedPackage(for: chromeFolder)
        #expect(chrome.kind == "chromium")
        #expect(chrome.firefoxID == nil)
    }

    /// A Firefox package added after the profile's extensions started still gets its pages' marker, in the scripts
    /// the controller hands its pages, once.
    @Test func aLaterFirefoxPackageIsMarkedInTheControllersPageScripts() throws {
        // The default profile's host: a profile made for the test would start its extensions after it's gone.
        let host = Profiles.shared.default.extensions
        #expect(host.pageScripts === host.controller.configuration.webViewConfiguration.userContentController)
        let id = "pbcodepdghnilmnkaebcgmmcgnenlfan"
        let marker = "if (location.host === '\(id)') { globalThis.__zigzagFirefoxPackage = true; }"
        host.addFirefoxMarker(id)
        host.addFirefoxMarker(id)
        host.addFirefoxMarker("not an id')")
        let sources = host.controller.configuration.webViewConfiguration.userContentController.userScripts.map(\.source)
        #expect(sources.filter { $0 == marker }.count == 1)
        #expect(!sources.contains { $0.contains("not an id") })
    }

    /// The installed record, not the manifest, decides who gets the Firefox marker.
    @Test func onlyAFirefoxRecordGetsTheFirefoxMarker() throws {
        let work = try Workspace()
        defer { work.cleanUp() }
        let firefox = "pbcodepdghnilmnkaebcgmmcgnenlfan"
        let chrome = "abcdefghijklmnopabcdefghijklmnop"
        ExtensionStore.save(ExtensionStore.Package(version: "1.0", kind: "firefox"), for: firefox)
        ExtensionStore.save(ExtensionStore.Package(version: "1.0"), for: chrome)
        // The assignment, not the name: the polyfill itself reads the global, so its text names it in every package.
        let marker = "globalThis.__zigzagFirefoxPackage = true;"
        let firefoxShim = try #require(ExtensionShims.shim(for: firefox))
        #expect(firefoxShim.backgroundPrelude?.contains(marker) == true)
        let chromeShim = try #require(ExtensionShims.shim(for: chrome))
        #expect(chromeShim.backgroundPrelude?.contains(marker) == false)
        // Pages get theirs from this list, set before the compatibility layer runs.
        #expect(ExtensionShims.firefoxIDs.contains(firefox))
        #expect(!ExtensionShims.firefoxIDs.contains(chrome))
    }
}

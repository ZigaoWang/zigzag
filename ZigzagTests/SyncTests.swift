import AppKit
import CloudKit
import Foundation
import Testing
@testable import Zigzag

// MARK: - A stand-in for iCloud, and Macs that sync with it

/// The private database's zone as CloudKit keeps it: each record with a change tag, saves that name a stale tag
/// refused, and a change log each Mac reads from where it left off.
@MainActor final class FakeCloud {
    struct Stored { var type: String; var payload: Data; var modified: Date; var tag: Int; var server: Date }
    private(set) var records: [String: Stored] = [:]
    private var log: [String] = []
    private var tags = 0
    /// iCloud's own clock: when it last saved something. It only goes forward.
    private var lastSave = Date(timeIntervalSince1970: 1_800_000_000)

    func remote(_ name: String) -> SyncRemote? {
        records[name].map { SyncRemote(name: name, type: $0.type, payload: $0.payload, modified: $0.modified, systemFields: Data(String($0.tag).utf8),
                                       serverModified: $0.server) }
    }

    enum Saved { case saved(SyncRemote), failed(SyncSaveFailure) }

    /// iCloud's copy reset (its encryption keys): the zone is there, empty.
    func reset() { records = [:] }

    /// The zone was removed (Remove from iCloud on another Mac).
    func removeZone() {
        records = [:]
        zoneRemoved = true
    }
    private(set) var zoneRemoved = false

    /// The zone made again, by the first sync after a reset.
    func makeZoneAgain() { zoneRemoved = false }

    /// `at`: the time it really is, as iCloud's clock has it; without one, the record's own date.
    @discardableResult
    func save(_ upload: SyncUpload, at: Date? = nil) -> Saved {
        if zoneRemoved { return .failed(.zoneMissing) }
        let tag = upload.systemFields.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        if let current = records[upload.name] {
            if tag != current.tag, let server = remote(upload.name) { return .failed(.conflict(server)) }
        } else if tag != nil {
            return .failed(.gone)
        }
        tags += 1
        lastSave = max(lastSave.addingTimeInterval(0.001), at ?? upload.modified)
        records[upload.name] = Stored(type: upload.type, payload: upload.payload, modified: upload.modified, tag: tags, server: lastSave)
        log.append(upload.name)
        return .saved(remote(upload.name)!)
    }

    /// Whether it was there.
    @discardableResult
    func delete(_ name: String) -> Bool {
        let was = records.removeValue(forKey: name) != nil
        log.append(name)
        return was
    }

    /// What changed since `token`: the records as they are now, and the names removed.
    func changes(since token: Int) -> (records: [SyncRemote], deleted: [String], token: Int) {
        let names = Set(log.dropFirst(token))
        return (names.compactMap(remote), names.filter { records[$0] == nil }, log.count)
    }
}

/// A library in memory, as a Mac's.
@MainActor final class MemoryHost: SyncHost {
    var library: SyncLibrary
    var libraryStamp: Date?
    var settingTimes: [String: Date] = [:]
    init(_ library: SyncLibrary) { self.library = library }
    func read() -> SyncLibrary { library }
    func write(_ library: SyncLibrary) {
        var library = library
        for i in library.contents.spaces.indices {
            let space = library.contents.spaces[i]
            let tidy = Library.tidied(space.bookmarks, space.folders ?? [], space.pinnedSplits ?? [])
            library.contents.spaces[i].bookmarks = tidy.bookmarks
            library.contents.spaces[i].folders = space.folders == nil && tidy.folders.isEmpty ? nil : tidy.folders
            library.contents.spaces[i].pinnedSplits = tidy.splits.isEmpty ? nil : tidy.splits
        }
        self.library = library
    }
}

/// One Mac: its library, its sync, and its link to the cloud, which can be cut.
@MainActor final class FakeMac: SyncServer, SyncTransport {
    let host: MemoryHost
    let session: SyncSession
    let cloud: FakeCloud
    var online = true
    /// Syncs that fail before one gets through, as iCloud refusing them (HTTP 500).
    var failing = 0
    /// A push said something changed: only then does a fetch of what's pending ask the server.
    var pushed = false
    /// The zone isn't in iCloud.
    var zoneMissing = false
    /// How far it has read, kept in the state as Zigzag keeps its own zone token.
    private var token: Int {
        get { session.state.zoneToken.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0 }
        set { session.updateState { $0.zoneToken = Data(String(newValue).utf8) } }
    }
    private(set) var saves: [String] = []
    private(set) var deletes: [String] = []
    private(set) var sent = 0
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// How far ahead of the real time this Mac's clock runs.
    var skew: TimeInterval = 0

    init(_ cloud: FakeCloud, _ library: SyncLibrary, clock: Date = Date(timeIntervalSince1970: 1_800_000_000), state: SyncState = SyncState()) {
        self.cloud = cloud
        host = MemoryHost(library)
        session = SyncSession(host: host, state: state)
        self.clock = clock
        session.server = self
        session.now = { [unowned self] in self.clock }
    }

    var library: SyncLibrary {
        get { host.library }
        set { host.library = newValue }
    }

    func queue(saves new: [String], deletes gone: [String]) {
        saves.removeAll { gone.contains($0) }
        deletes.removeAll { new.contains($0) }
        for name in new where !saves.contains(name) { saves.append(name) }
        for name in gone where !deletes.contains(name) { deletes.append(name) }
    }

    /// A change made here, a second after the last.
    func edit(_ change: (inout SyncLibrary) -> Void) {
        clock += 1
        change(&host.library)
        session.localChanged()
    }

    /// Fetches, then sends, until nothing's left to send, as CKSyncEngine does.
    func sync() {
        guard online else { return }
        clock += 1
        for _ in 0..<6 {
            fetch()
            if saves.isEmpty && deletes.isEmpty { return }
            send()
        }
    }

    /// A sync that throws while iCloud refuses it.
    func trySync() throws {
        if failing > 0 {
            failing -= 1
            throw CKError(.serverRejectedRequest)
        }
        sync()
    }

    /// As CKSyncEngine: the records arrive, and once merged the fetch settles them itself.
    func fetchChanges(_ scope: SyncFetchScope) async throws {
        if failing > 0 {
            failing -= 1
            throw CKError(.serverRejectedRequest)
        }
        guard scope == .zone || pushed else { return }
        pushed = false
        if zoneMissing { throw CKError(.zoneNotFound) }
        read()
        if session.state.merged { session.fetchFinished() }
    }

    func sendChanges() async throws {
        zoneMissing = false
        send()
    }

    func fetch() {
        read()
        session.fetchFinished()
    }

    /// As CloudKit: read from the start, it lists what's there and no removals.
    private func read() {
        let changes = cloud.changes(since: token)
        let all = token == 0
        token = changes.token
        session.fetched(changes.records, deleted: all ? [] : changes.deleted)
        if all { session.readAll(Set(changes.records.map(\.name)), startedAt: clock) }
    }

    func send() {
        let names = saves, gone = deletes
        saves = []
        deletes = []
        var saved: [SyncRemote] = []
        for name in names {
            guard let upload = session.upload(name) else { continue }
            sent += 1
            switch cloud.save(upload, at: clock - skew) {
            case .saved(let record): saved.append(record)
            case .failed(let failure): session.saveFailed(name, failure)
            }
        }
        session.saved(saved)
        var removed: [String] = []
        for name in gone {
            if cloud.delete(name) { removed.append(name) } else { session.deleteFailed(name, .gone) }
        }
        session.deleted(removed)
    }
}

// MARK: - Libraries to sync

@MainActor enum Sample {
    static func page(_ path: String, _ title: String? = nil) -> Bookmark {
        Bookmark(url: URL(string: "https://example.com/\(path)")!, title: title ?? path)
    }

    static func library(_ spaces: [SpaceInfo], favorites: [Bookmark] = [], directory: ProfileDirectory = ProfileDirectory(), settings: [String: SettingValue] = [:]) -> SyncLibrary {
        SyncLibrary(contents: Library.Contents(spaces: spaces, favorites: favorites, favoriteSplits: [], siteRoutes: [], directory: directory),
                    searchEngine: .google, settings: settings)
    }

    static func space(_ name: String, _ pages: [Bookmark] = [], folders: [BookmarkFolder]? = nil) -> SpaceInfo {
        var space = SpaceInfo(name: name, color: .sky)
        space.bookmarks = pages
        space.folders = folders
        return space
    }
}

extension SyncLibrary {
    func space(named name: String) -> SpaceInfo? { contents.spaces.first { $0.name == name } }
    var spaceNames: [String] { contents.spaces.map(\.name) }
    func titles(in name: String) -> [String] { space(named: name)?.bookmarks.map(\.title) ?? [] }
    func urls(in name: String) -> [String] { space(named: name)?.bookmarks.map(\.url.lastPathComponent) ?? [] }

    mutating func editSpace(_ name: String, _ change: (inout SpaceInfo) -> Void) {
        guard let i = contents.spaces.firstIndex(where: { $0.name == name }) else { return }
        change(&contents.spaces[i])
    }
}

// MARK: - Tests

/// Sync with iCloud (#459): the records, their order, the first sync's merge, and two Macs editing at once, through
/// an iCloud stand-in. specs/sync.md.
@MainActor struct SyncTests {
    // MARK: Records

    @Test func everyKindReadsBackAsItWasWritten() {
        var look = SpaceInfo(name: "Work", color: .rose)
        look.icon = "briefcase"
        look.hue = 0.3
        look.glass = true
        let space = SyncSpace(look: look, profile: Profile.defaultID, position: "i", splits: [PinnedSplit(left: UUID(), right: UUID())])
        let source = LiveSource.feed(URL(string: "https://example.com/feed")!)
        let bodies: [SyncBody] = [
            .space(space),
            .profile(SyncProfile(name: "Home", color: .sage, position: "a", favoriteSplits: [])),
            .page(SyncPage(url: URL(string: "https://example.com/a")!, title: "A", icon: "🙂", space: UUID(), parent: UUID(), position: "b")),
            .folder(SyncFolder(name: "Docs", icon: nil, isOpen: false, space: UUID(), parent: nil, position: "c", live: .init(source: source, limit: 10, namedByFeed: true))),
            .favorite(SyncFavorite(url: URL(string: "https://mail.example.com")!, title: "Mail", icon: nil, profile: Profile.defaultID, position: "d")),
            .rules(SyncRules(routes: [SiteRoutes.Route(site: "example.com", spaceID: UUID())])),
            .settings(SyncSettings(values: ["ReaderSize": .init(value: .int(18), modified: Date(timeIntervalSince1970: 100)),
                                            "DarkPages": .init(value: nil, modified: Date(timeIntervalSince1970: 200))])),
        ]
        for body in bodies {
            let item = SyncItem(body, modified: Date(timeIntervalSince1970: 5))
            let read = SyncItem(item.body, modified: item.modified)
            #expect(read == item, "\(body.recordType) changed on the way back")
            if case .unknown = item.body { Issue.record("\(body.recordType) didn't read back") }
        }
        guard case .space(let back) = SyncItem(.space(space), modified: Date()).body else { Issue.record("no space"); return }
        #expect(back.look.name == "Work" && back.look.icon == "briefcase" && back.look.glass == true && back.splits.count == 1)
        // What only this Mac has stays out of the record.
        var local = look
        local.backgroundImage = "picture.heic"
        local.importedFrom = "arc:1"
        local.bookmarks = [Sample.page("a")]
        let stripped = SyncSpace(look: local, profile: Profile.defaultID, position: "a", splits: [])
        #expect(stripped.look.backgroundImage == nil && stripped.look.importedFrom == nil && stripped.look.bookmarks.isEmpty)
    }

    @Test func olderAndNewerRecordsStillRead() {
        // Fields left out read as their defaults; fields a newer Zigzag added are ignored.
        let page = SyncBody.decode(type: SyncBody.pageType, payload: Data(#"{"url":"https://example.com/a","space":"\#(UUID().uuidString)","future":{"x":1}}"#.utf8))
        guard case .page(let p) = page else { Issue.record("page didn't read"); return }
        #expect(p.title == "" && p.parent == nil && p.position == "")
        let profile = SyncBody.decode(type: SyncBody.profileType, payload: Data(#"{"name":"Work","color":"ultraviolet"}"#.utf8))
        guard case .profile(let pr) = profile else { Issue.record("profile didn't read"); return }
        #expect(pr.name == "Work" && pr.color == nil)
        let folder = SyncBody.decode(type: SyncBody.folderType, payload: Data(#"{"name":"F","space":"\#(UUID().uuidString)","live":{"source":{"gitHub":"someday"}}}"#.utf8))
        guard case .folder(let f) = folder else { Issue.record("folder didn't read"); return }
        #expect(f.isOpen && f.live != nil)
        let settings = SyncBody.decode(type: SyncBody.settingsType, payload: Data(#"{"values":{"A":{"value":true,"modified":1},"B":"broken"}}"#.utf8))
        guard case .settings(let s) = settings else { Issue.record("settings didn't read"); return }
        #expect(s.values.keys.sorted() == ["A"])
        // A kind only a newer Zigzag knows is kept as it came, and a damaged record too.
        #expect({ if case .unknown = SyncBody.decode(type: "Reminder", payload: Data("{}".utf8)) { true } else { false } }())
        #expect({ if case .unknown = SyncBody.decode(type: SyncBody.pageType, payload: Data("{".utf8)) { true } else { false } }())
    }

    @Test func aNewerZigzagsFieldsSurviveAnEditHere() {
        let server = Data(#"{"url":"https://example.com/old","title":"Old","space":"\#(UUID().uuidString)","position":"a","future":"kept","icon":"star"}"#.utf8)
        let mine = SyncBody.page(SyncPage(url: URL(string: "https://example.com/new")!, title: "New", icon: nil, space: UUID(), parent: nil, position: "b")).encoded()
        let sent = (try? JSONSerialization.jsonObject(with: SyncBody.overlay(mine, on: server, type: SyncBody.pageType))) as? [String: Any]
        #expect(sent?["future"] as? String == "kept")
        #expect(sent?["title"] as? String == "New")
        // A field this version cleared stays cleared.
        #expect(sent?["icon"] == nil)
    }

    @Test func aSpaceRecordKnowsEveryKeyASpaceWrites() throws {
        var look = SpaceInfo(name: "All", color: .rose, defaultColor: .sky)
        look.hue = 1; look.intensity = 1; look.appearance = "dark"; look.grain = 1; look.hue2 = 1; look.intensity2 = 1; look.angle = 1
        look.glass = true; look.brightness = 1; look.brightness2 = 1; look.dayDepth = 1; look.nightDepth = 1; look.tint = 1; look.tint2 = 1
        look.translucency = 1; look.clearGlass = true; look.clearTint = true; look.texture = "paper"; look.icon = "star"
        let json = try #require(try JSONSerialization.jsonObject(with: SyncBody.space(SyncSpace(look: look, profile: UUID(), position: "a", splits: [])).encoded()) as? [String: Any])
        #expect(Set(json.keys).isSubset(of: SyncSpace.knownKeys), "\(Set(json.keys).subtracting(SyncSpace.knownKeys))")
    }

    // MARK: Order

    @Test func placesSortBetweenTheirNeighbors() {
        let a = SyncOrder.between(nil, nil)
        let b = SyncOrder.between(a, nil)
        let c = SyncOrder.between(a, b)
        let d = SyncOrder.between(nil, a)
        #expect(d < a && a < c && c < b)
        var last: String? = nil
        for _ in 0..<1000 { let next = SyncOrder.between(last, nil); #expect(last.map { $0 < next } ?? true); last = next }
        var low = "a", high = "b"
        for _ in 0..<200 { let mid = SyncOrder.between(low, high); #expect(low < mid && mid < high); high = mid }
        low = SyncOrder.between(nil, high)
        #expect(low < high)
    }

    @Test func aMoveChangesOnlyThePlaceOfWhatMoved() {
        let ids = (0..<20).map { _ in UUID() }
        let first = SyncOrder.keys(for: ids, existing: [:])
        #expect(ids.map { first[$0]! } == ids.map { first[$0]! }.sorted())
        var moved = ids
        moved.insert(moved.remove(at: 15), at: 2)
        let second = SyncOrder.keys(for: moved, existing: first)
        #expect(moved.map { second[$0]! } == moved.map { second[$0]! }.sorted())
        #expect(moved.filter { first[$0] != second[$0] } == [ids[15]])
        // A thousand pages added one after another keep short places.
        var many: [UUID] = [], keys: [UUID: String] = [:]
        for _ in 0..<1000 { many.append(UUID()); keys = SyncOrder.keys(for: many, existing: keys) }
        #expect(keys.values.allSatisfy { $0.count <= SyncOrder.longest })
        #expect(many.map { keys[$0]! } == many.map { keys[$0]! }.sorted())
        // Pages added again and again at one spot renumber only around it, never the whole list.
        let original = (0..<100).map { _ in UUID() }
        var list = original
        var places = SyncOrder.keys(for: list, existing: [:])
        let start = places
        for _ in 0..<300 { list.insert(UUID(), at: 51); places = SyncOrder.keys(for: list, existing: places) }
        #expect(list.map { places[$0]! } == list.map { places[$0]! }.sorted())
        #expect(places.values.allSatisfy { $0.count <= SyncOrder.longest })
        let far = original.prefix(20) + original.suffix(20)
        #expect(far.allSatisfy { places[$0] == start[$0] }, "\(far.filter { places[$0] != start[$0] }.count) far from the spot renumbered")
    }

    // MARK: The first sync

    @Test func aSecondMacsFirstSpaceIsMatchedByNameNotCopied() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("news"), Sample.page("mail")])]))
        a.sync()
        #expect(cloud.records.count > 0)
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal")]))
        b.sync()
        #expect(b.library.spaceNames == ["Personal"])
        #expect(b.library.urls(in: "Personal") == ["news", "mail"])
        // B's space keeps its own ID here: open tabs still find it.
        let bID = b.library.contents.spaces[0].id
        #expect(bID != a.library.contents.spaces[0].id)
        a.sync()
        #expect(a.library.spaceNames == ["Personal"])
    }

    @Test func theFirstSyncMergesDuplicatesByNameAndAddress() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Work", [Sample.page("docs", "Docs A"), Sample.page("only-a")]), Sample.space("Home", [Sample.page("cook")])]))
        a.sync()
        let b = FakeMac(cloud, Sample.library([Sample.space("work ", [Sample.page("docs", "Docs B"), Sample.page("only-b")]), Sample.space("Play", [Sample.page("game")])]))
        b.sync()
        a.sync()
        b.sync()
        for mac in [a, b] {
            #expect(Set(mac.library.spaceNames) == ["Work", "Home", "Play"], "\(mac.library.spaceNames)")
            let work = mac.library.contents.spaces.first { $0.name.lowercased().hasPrefix("work") }
            #expect(work?.bookmarks.map(\.url.lastPathComponent).sorted() == ["docs", "only-a", "only-b"])
            // The page both had is one page, as iCloud had it.
            #expect(work?.bookmarks.first { $0.url.lastPathComponent == "docs" }?.title == "Docs A")
        }
        #expect(a.library.spaceNames == b.library.spaceNames)
        #expect(a.library.urls(in: "Work") == b.library.urls(in: "Work"))
    }

    @Test func pinsThatDifferOnlyAfterTheHashStayTwo() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("app#inbox")])], favorites: [Sample.page("mail#one")]))
        a.sync()
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("app#sent"), Sample.page("app#inbox")])], favorites: [Sample.page("mail#two")]))
        b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.space(named: "Personal")?.bookmarks.map { $0.url.fragment ?? "" }.sorted() == ["inbox", "sent"])
            #expect(mac.library.contents.favorites.map { $0.url.fragment ?? "" }.sorted() == ["one", "two"])
        }
    }

    @Test func twoMacsTurningSyncOnAtOnceMakeNoCopies() {
        // Whichever Mac's IDs sort first.
        for _ in 0..<12 { twoFirstSyncsAtOnce() }
    }

    private func twoFirstSyncsAtOnce() {
        let cloud = FakeCloud()
        var one = ProfileDirectory(), two = ProfileDirectory()
        _ = one.add(name: "Work")
        _ = two.add(name: "Work")
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("y")])], favorites: [Sample.page("mail")], directory: one))
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("y"), Sample.page("z")])], favorites: [Sample.page("mail")], directory: two))
        // Both read an empty iCloud before either sends.
        a.fetch(); b.fetch()
        a.send(); b.send()
        for _ in 0..<3 { a.sync(); b.sync() }
        for (n, mac) in [("a", a), ("b", b)] {
            #expect(mac.library.spaceNames == ["Personal"], "\(n)")
            #expect(mac.library.urls(in: "Personal").sorted() == ["x", "y", "z"])
            #expect(mac.library.contents.favorites.count == 1)
            #expect(mac.library.contents.directory.all.filter { $0.name == "Work" }.count == 1, "\(n)")
        }
        #expect(cloud.records.keys.filter { $0.hasPrefix("space.") }.count == 1)
        #expect(cloud.records.keys.filter { $0.hasPrefix("page.") }.count == 3)
        #expect(cloud.records.keys.filter { $0.hasPrefix("profile.") }.count == 2)
        let sent = a.sent + b.sent
        a.sync(); b.sync()
        #expect(a.sent + b.sent == sent)
    }

    @Test func theFirstSyncNeverRemovesWhatIsOnlyHere() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        a.sync()
        let folder = BookmarkFolder(name: "Mine")
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("b1"), Sample.page("b2")], folders: [folder]), Sample.space("Extra")],
                                             favorites: [Sample.page("fav")]))
        b.sync()
        #expect(b.library.urls(in: "Personal").sorted() == ["a", "b1", "b2"])
        #expect(b.library.space(named: "Personal")?.folders?.map(\.name) == ["Mine"])
        #expect(b.library.spaceNames.contains("Extra"))
        #expect(b.library.contents.favorites.map(\.url.lastPathComponent) == ["fav"])
        a.sync()
        #expect(a.library.urls(in: "Personal").sorted() == ["a", "b1", "b2"])
        #expect(a.library.contents.favorites.map(\.url.lastPathComponent) == ["fav"])
    }

    @Test func turningSyncOffRenamingAndOnAgainAddsNoCopy() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        // B's space matched A's by name; sync turns off on B, the space is renamed, and sync turns on again.
        let off = try saved(ICloudSync.stateTurningOff(b.session.state))
        #expect(off.account == nil && off.engine == nil && off.zoneToken == nil)
        var library = b.library
        library.editSpace("Personal") { $0.name = "Home" }
        let again = FakeMac(cloud, library, clock: b.clock + 10, state: ICloudSync.stateTurningOn(saved: off))
        again.session.checkAfterLaunch()
        again.sync(); a.sync()
        #expect(again.library.spaceNames == ["Home"] && again.library.urls(in: "Personal").isEmpty && again.library.urls(in: "Home") == ["a"])
        #expect(a.library.spaceNames == ["Home"])
        #expect(cloud.records.keys.filter { $0.hasPrefix("space.") }.count == 1)
    }

    @Test func turningSyncOnAgainKeepsWhatChangedOnEachSideWhileOff() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b"), Sample.page("c"), Sample.page("d")])]))
        let off = try saved(ICloudSync.stateTurningOff(b.session.state))
        // While B is off: B retitles a and removes c; A retitles b, removes d and pins e.
        var library = b.library
        library.editSpace("Personal") { s in
            s.bookmarks[0].title = "retitled while off"
            s.bookmarks.removeAll { $0.url.lastPathComponent == "c" }
        }
        a.edit { $0.editSpace("Personal") { s in
            s.bookmarks[1].title = "retitled in iCloud"
            s.bookmarks.removeAll { $0.url.lastPathComponent == "d" }
            s.bookmarks.append(Sample.page("e"))
        } }
        a.sync()
        let again = FakeMac(cloud, library, clock: b.clock + 86400, state: ICloudSync.stateTurningOn(saved: off))
        again.session.checkAfterLaunch()
        again.sync(); a.sync()
        for mac in [again, a] {
            #expect(mac.library.titles(in: "Personal") == ["retitled while off", "retitled in iCloud", "e"], "\(mac.library.titles(in: "Personal"))")
        }
    }

    @Test func turningSyncOnAgainAfterRemoveFromICloudMergesAfresh() {
        let (_, _, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let off = ICloudSync.stateTurningOff(b.session.state, keepingLibrary: false)
        #expect(!off.merged && off.base.isEmpty && !off.aliases.isEmpty)
    }

    @Test func aResetWhileAnotherMacWasOfflineAddsNoCopies() {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        // B goes offline and renames its space; iCloud's copy is reset meanwhile and A sends its library again.
        b.online = false
        b.edit { $0.editSpace("Personal") { $0.name = "Home" } }
        cloud.reset()
        a.session.startOver()
        a.sync()
        b.online = true
        b.session.startOver()
        b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.contents.spaces.count == 1)
            #expect(mac.library.contents.spaces[0].bookmarks.map(\.url.lastPathComponent) == ["a", "b"])
        }
        #expect(cloud.records.keys.filter { $0.hasPrefix("space.") || $0.hasPrefix("page.") }.count == 3)
    }

    @Test func aLibraryThatCouldntBeReadIsFilledFromICloudNotEmptiedInto() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a")]), Sample.space("Work", [Sample.page("b")])], favorites: [Sample.page("fav")]))
        a.sync()
        let records = cloud.records.count
        // Zigzag starts again with a new library (the file couldn't be read): what sync kept is put aside, and it merges again.
        let state = ICloudSync.stateAtLaunch(saved: a.session.state, libraryWasRead: false)
        #expect(!state.merged && state.base.isEmpty && state.engine == nil && state.account == a.session.state.account)
        let again = FakeMac(cloud, Sample.library([Sample.space("Personal")]), clock: a.clock, state: state)
        again.sync()
        #expect(cloud.records.count == records)
        #expect(again.library.spaceNames == ["Personal", "Work"])
        #expect(again.library.urls(in: "Work") == ["b"])
        #expect(again.library.contents.favorites.map(\.url.lastPathComponent) == ["fav"])
        // Read as usual, it carries on.
        #expect(ICloudSync.stateAtLaunch(saved: a.session.state, libraryWasRead: true).merged)
    }

    @Test func aFirstSyncCutShortReadsICloudAgainFromTheStart() {
        var state = SyncState()
        state.engine = Data("token".utf8)
        state.account = "_abc"
        let next = ICloudSync.stateAtLaunch(saved: state, libraryWasRead: true)
        #expect(next.engine == nil && next.account == "_abc")
        state.merged = true
        #expect(ICloudSync.stateAtLaunch(saved: state, libraryWasRead: true).engine == state.engine)
    }

    @Test func turningSyncOnAgainAddsNothingTwice() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        a.sync()
        let count = cloud.records.count
        // Off and on again (or iCloud's copy reset): merged once more, as on a first sync.
        a.session.startOver()
        a.sync()
        #expect(cloud.records.count == count)
        #expect(a.library.urls(in: "Personal") == ["a", "b"])
    }

    // MARK: Two Macs at once

    private func twoMacs(_ library: SyncLibrary) -> (FakeCloud, FakeMac, FakeMac) {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, library)
        a.sync()
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal")]), clock: a.clock)
        b.sync()
        a.sync()
        return (cloud, a, b)
    }

    @Test func editsToDifferentThingsBothArrive() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        a.edit { $0.editSpace("Personal") { $0.name = "Mine" } }
        b.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("c")) } }
        a.sync(); b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.spaceNames == ["Mine"])
            #expect(mac.library.urls(in: "Mine") == ["a", "b", "c"])
        }
    }

    @Test func theLastEditToOnePageWins() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "From A" } }
        b.clock = a.clock + 10
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "From B" } }
        // A sends first; B's save meets A's newer tag, and B's later edit wins.
        a.sync(); b.sync(); a.sync()
        #expect(a.library.titles(in: "Personal") == ["From B"])
        #expect(b.library.titles(in: "Personal") == ["From B"])
        // An older edit loses, whoever sends last.
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "Older" } }
        a.clock = b.clock + 10
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "Newer" } }
        b.sync(); a.sync(); b.sync()
        #expect(a.library.titles(in: "Personal") == ["Newer"])
        #expect(b.library.titles(in: "Personal") == ["Newer"])
    }

    @Test func aMacWhoseClockRunsAheadDoesntWinALaterEdit() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        // B's clock runs an hour fast. B renames the page, then A renames it a minute later.
        b.skew = 3600
        b.clock = a.clock + 3600
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "From B" } }
        b.sync()
        a.clock = b.clock - 3600 + 60
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "From A, later" } }
        a.sync(); b.sync(); a.sync()
        #expect(a.library.titles(in: "Personal") == ["From A, later"])
        #expect(b.library.titles(in: "Personal") == ["From A, later"])
        // B edits offline; A edits a minute later and sends first. B's own clock doesn't make its earlier edit win.
        b.online = false
        b.clock += 120
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "B, offline" } }
        a.clock = b.clock - 3600 + 60
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "A, a minute after" } }
        a.sync()
        b.online = true
        b.sync(); a.sync()
        #expect(a.library.titles(in: "Personal") == ["A, a minute after"])
        #expect(b.library.titles(in: "Personal") == ["A, a minute after"])
        // A later edit on B still wins.
        b.clock = a.clock + 3600 + 60
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "B, later still" } }
        b.sync(); a.sync()
        #expect(a.library.titles(in: "Personal") == ["B, later still"])
        // Preferences the same way, key by key.
        b.clock += 60
        b.edit { $0.settings["ReaderSize"] = .int(14) }
        b.sync()
        a.clock = b.clock - 3600 + 60
        a.edit { $0.settings["ReaderSize"] = .int(22) }
        a.sync(); b.sync(); a.sync()
        #expect(a.library.settings["ReaderSize"] == .int(22))
        #expect(b.library.settings["ReaderSize"] == .int(22))
    }

    @Test func aMoveAndAnInsertAtOnceBothKeepTheirPlaces() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", ["1", "2", "3", "4", "5"].map { Sample.page($0) })]))
        // A drags 5 to the top; B pins a new page between 2 and 3.
        a.edit { $0.editSpace("Personal") { $0.bookmarks.insert($0.bookmarks.removeLast(), at: 0) } }
        b.edit { $0.editSpace("Personal") { $0.bookmarks.insert(Sample.page("new"), at: 2) } }
        a.sync(); b.sync(); a.sync()
        #expect(a.library.urls(in: "Personal") == ["5", "1", "2", "new", "3", "4"])
        #expect(b.library.urls(in: "Personal") == a.library.urls(in: "Personal"))
    }

    @Test func editsMadeOfflineArriveWhenBackOnline() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        b.online = false
        b.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("offline 1")) } }
        b.edit { $0.editSpace("Personal") { $0.icon = "airplane" } }
        b.edit { $0.contents.spaces.append(Sample.space("Trip", [Sample.page("hotel")])) }
        a.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("online")) } }
        a.sync()
        b.sync()
        #expect(a.library.urls(in: "Personal") == ["a", "online"])
        b.online = true
        b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.urls(in: "Personal").sorted() == ["a", "offline 1", "online"])
            #expect(mac.library.space(named: "Personal")?.icon == "airplane")
            #expect(mac.library.urls(in: "Trip") == ["hotel"])
        }
    }

    @Test func aPageAddedToAFolderRemovedElsewhereMovesToTheTopOfItsSpace() {
        let folder = BookmarkFolder(name: "Docs", bookmarkIDs: [])
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")], folders: [folder])]))
        let folderHere = b.library.space(named: "Personal")?.folders?.first?.id
        #expect(folderHere != nil)
        // A removes the folder; B files a new page into it.
        a.edit { $0.editSpace("Personal") { $0.folders = [] } }
        b.edit { lib in
            lib.editSpace("Personal") { space in
                let page = Sample.page("filed")
                space.bookmarks.append(page)
                space.folders?[0].bookmarkIDs = [page.id]
            }
        }
        a.sync(); b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.urls(in: "Personal").contains("filed"), "\(mac.library.urls(in: "Personal"))")
            #expect(mac.library.space(named: "Personal")?.folders?.isEmpty ?? true)
        }
    }

    @Test func aPageEditedHereComesBackWhenRemovedElsewhere() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        a.edit { $0.editSpace("Personal") { $0.bookmarks.removeAll { $0.url.lastPathComponent == "b" } } }
        b.edit { $0.editSpace("Personal") { if let i = $0.bookmarks.firstIndex(where: { $0.url.lastPathComponent == "b" }) { $0.bookmarks[i].title = "Renamed" } } }
        a.sync(); b.sync(); a.sync()
        #expect(a.library.titles(in: "Personal") == ["a", "Renamed"])
        #expect(b.library.titles(in: "Personal") == ["a", "Renamed"])
    }

    @Test func removalsReachTheOtherMac() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")]), Sample.space("Old", [Sample.page("x")])],
                                                favorites: [Sample.page("fav")]))
        a.edit { lib in
            lib.editSpace("Personal") { $0.bookmarks.removeFirst() }
            lib.contents.spaces.removeAll { $0.name == "Old" }
            lib.contents.favorites = []
        }
        a.sync(); b.sync()
        #expect(b.library.urls(in: "Personal") == ["b"])
        #expect(b.library.spaceNames == ["Personal"])
        #expect(b.library.contents.favorites.isEmpty)
    }

    @Test func aSpaceRemovedElsewhereKeepsAPageJustPinnedInIt() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")]), Sample.space("Old")]))
        a.edit { $0.contents.spaces.removeAll { $0.name == "Old" } }
        b.edit { $0.editSpace("Old") { $0.bookmarks.append(Sample.page("rescued")) } }
        a.sync(); b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.spaceNames == ["Personal"])
            #expect(mac.library.urls(in: "Personal").sorted() == ["a", "rescued"])
        }
    }

    @Test func foldersNestingIconsAndFoldStateSync() {
        let inner = Sample.page("inner"), deep = Sample.page("deep")
        let outer = BookmarkFolder(name: "Outer", bookmarkIDs: [inner.id], icon: "📚")
        let sub = BookmarkFolder(name: "Sub", bookmarkIDs: [deep.id], parentID: outer.id)
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("top"), inner, deep], folders: [outer, sub])]))
        let folders = b.library.space(named: "Personal")?.folders ?? []
        #expect(folders.map(\.name).sorted() == ["Outer", "Sub"])
        let outerHere = folders.first { $0.name == "Outer" }
        #expect(outerHere?.icon == "📚")
        #expect(folders.first { $0.name == "Sub" }?.parentID == outerHere?.id)
        #expect(b.library.urls(in: "Personal") == ["top", "inner", "deep"])
        a.edit { $0.editSpace("Personal") { space in if let i = space.folders?.firstIndex(where: { $0.name == "Outer" }) { space.folders?[i].isOpen = false } } }
        a.sync(); b.sync()
        #expect(b.library.space(named: "Personal")?.folders?.first { $0.name == "Outer" }?.isOpen == false)
    }

    @Test func aPinnedSplitStaysASplit() {
        let left = Sample.page("left"), right = Sample.page("right")
        var space = Sample.space("Personal", [Sample.page("a"), left, right])
        space.pinnedSplits = [PinnedSplit(left: left.id, right: right.id)]
        let (_, _, b) = twoMacs(Sample.library([space]))
        let here = b.library.space(named: "Personal")
        let ids = here?.bookmarks.map(\.id) ?? []
        #expect(here?.pinnedSplits?.first?.ids == ids.suffix(2).map { $0 })
        #expect(b.library.urls(in: "Personal") == ["a", "left", "right"])
    }

    @Test func aLiveFolderSyncsItsSourceNotItsPages() {
        let fetched = Sample.page("story")
        var folder = BookmarkFolder(name: "News", bookmarkIDs: [fetched.id])
        folder.live = LiveFolder(source: .feed(URL(string: "https://example.com/feed")!), limit: 10, namedByFeed: false,
                                 items: [LiveItem(key: "1", url: fetched.url, title: fetched.title, bookmarkID: fetched.id)])
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), fetched], folders: [folder])]))
        #expect(!cloud.records.keys.contains(SyncName.page(fetched.id)))
        let there = b.library.space(named: "Personal")?.folders?.first
        #expect(there?.live?.source.address?.absoluteString == "https://example.com/feed")
        #expect(there?.live?.limit == 10)
        #expect(there?.live?.items.isEmpty == true)
        #expect(b.library.urls(in: "Personal") == ["a"])
        // A changes its count; A's own fetched pages stay.
        a.edit { $0.editSpace("Personal") { $0.folders?[0].live?.limit = 25 } }
        a.sync(); b.sync()
        #expect(b.library.space(named: "Personal")?.folders?.first?.live?.limit == 25)
        #expect(a.library.urls(in: "Personal") == ["a", "story"])
    }

    @Test func profilesAndTheirFavoritesSync() {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        let office = Sample.space("Office", [Sample.page("jira")])
        directory.assign(space: office.id, to: work.id)
        let mail = Sample.page("mail"), chat = Sample.page("chat")
        directory.assign(favorite: chat.id, to: work.id)
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal"), office], favorites: [mail, chat], directory: directory))
        let dir = b.library.contents.directory
        #expect(dir.all.map(\.displayName) == ["Default", "Work"])
        let officeHere = b.library.space(named: "Office")
        #expect(officeHere.map { dir.profileID(ofSpace: $0.id) } == work.id)
        #expect(b.library.contents.favorites.filter { dir.profileID(ofFavorite: $0.id) == work.id }.map(\.url.lastPathComponent) == ["chat"])
    }

    @Test func aProfileRemovedOnAnotherMacStaysHereWithItsSpaces() {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        let office = Sample.space("Office", [Sample.page("jira")])
        directory.assign(space: office.id, to: work.id)
        let chat = Sample.page("chat")
        directory.assign(favorite: chat.id, to: work.id)
        let offSites = "\(ProfileKey.extensionsOffSites.rawValue).\(work.id.uuidString)"
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal"), office], favorites: [chat], directory: directory,
                                                   settings: [offSites: .array([.string("example.com")])]))
        #expect(b.library.settings[offSites] == .array([.string("example.com")]))
        // Removed on A as Profiles removes one: its spaces go to the first profile, its favorites and its own settings go.
        a.edit { lib in
            var d = lib.contents.directory
            d.remove(work.id)
            lib.contents.directory = d
            lib.contents.favorites.removeAll { $0.id == chat.id }
            lib.settings[offSites] = nil
        }
        a.sync(); b.sync(); a.sync(); b.sync()
        // B keeps the profile, its space on it, its favorite and its settings.
        let dir = b.library.contents.directory
        #expect(dir.profile(work.id) != nil)
        #expect(b.library.space(named: "Office").map { dir.profileID(ofSpace: $0.id) } == work.id)
        #expect(b.library.contents.favorites.map(\.id) == [chat.id])
        #expect(dir.profileID(ofFavorite: chat.id) == work.id)
        #expect(b.library.settings[offSites] == .array([.string("example.com")]))
        // The space still syncs; the profile isn't sent back to A, and nothing goes back and forth.
        #expect(b.library.titles(in: "Office") == ["jira"])
        #expect(a.library.contents.directory.profile(work.id) == nil)
        #expect(cloud.records[SyncName.profile(work.id)] == nil)
        #expect(cloud.records[SyncName.space(office.id)] != nil)
        let sentA = a.sent, sentB = b.sent
        a.sync(); b.sync(); b.session.localChanged(); b.sync(); a.sync()
        #expect(a.sent == sentA && b.sent == sentB)
        a.edit { $0.editSpace("Office") { $0.bookmarks.append(Sample.page("wiki")) } }
        a.sync(); b.sync()
        #expect(b.library.titles(in: "Office") == ["jira", "wiki"])
        #expect(b.library.space(named: "Office").map { b.library.contents.directory.profileID(ofSpace: $0.id) } == work.id)
    }

    @Test func aProfilesFavoritesRemovedBeforeItStayWithItHere() throws {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        let chat = Sample.page("chat")
        directory.assign(favorite: chat.id, to: work.id)
        let offSites = "\(ProfileKey.extensionsOffSites.rawValue).\(work.id.uuidString)"
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal")], favorites: [chat], directory: directory,
                                                   settings: [offSites: .array([.string("example.com")])]))
        a.edit { lib in
            var d = lib.contents.directory
            d.remove(work.id)
            lib.contents.directory = d
            lib.contents.favorites.removeAll { $0.id == chat.id }
            lib.settings[offSites] = nil
        }
        a.sync()
        // B reads the favorite's removal and the settings first, and the profile's removal in a later fetch.
        let all = cloud.changes(since: 0)
        let profile = SyncName.profile(work.id)
        b.session.fetched(all.records, deleted: all.deleted.filter { $0 != profile })
        b.session.fetchFinished()
        #expect(b.library.contents.favorites.isEmpty)
        b.session.fetched([], deleted: [profile])
        b.session.fetchFinished()
        let dir = b.library.contents.directory
        #expect(dir.profile(work.id) != nil)
        #expect(b.library.contents.favorites.map(\.id) == [chat.id])
        #expect(dir.profileID(ofFavorite: chat.id) == work.id)
        #expect(b.library.settings[offSites] == .array([.string("example.com")]))
        let sent = b.sent
        b.sync(); a.sync()
        #expect(b.sent == sent && cloud.records[SyncName.favorite(chat.id)] == nil)
    }

    @Test func aSecondMacsProfileOfTheSameNameIsTheSameProfile() {
        var one = ProfileDirectory()
        let workA = one.add(name: "Work")
        var two = ProfileDirectory()
        let workB = two.add(name: "Work")
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal")], directory: one))
        a.sync()
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal")], directory: two))
        b.sync()
        // B's profile keeps its ID (its website data is under it) and is iCloud's Work.
        #expect(b.library.contents.directory.all.map(\.id) == [Profile.defaultID, workB.id])
        #expect(cloud.records.keys.filter { $0.hasPrefix("profile.") }.sorted() == [SyncName.profile(Profile.defaultID), SyncName.profile(workA.id)].sorted())
    }

    // MARK: Preferences

    @Test func siteRulesAndSplitsEditedOnTwoMacsKeepBoth() throws {
        let one = Sample.page("one"), two = Sample.page("two"), three = Sample.page("three")
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [one, two, three])]))
        let space = try #require(a.library.contents.spaces.first?.id)
        let old = SiteRoutes.Route(site: "old.com", spaceID: space)
        a.edit { $0.contents.siteRoutes = [old] }
        a.sync(); b.sync()
        // At once: A adds a rule and renames the space, B adds another rule, removes the old one and pins a split.
        a.edit { $0.contents.siteRoutes.append(SiteRoutes.Route(site: "a.com", spaceID: space)); $0.editSpace("Personal") { $0.name = "Home" } }
        b.edit { lib in
            lib.contents.siteRoutes = [SiteRoutes.Route(site: "b.com", spaceID: lib.contents.spaces[0].id)]
            lib.editSpace("Personal") { s in
                let ids = s.bookmarks.map(\.id)
                s.pinnedSplits = [PinnedSplit(left: ids[1], right: ids[2])]
            }
        }
        b.sync(); a.sync(); b.sync(); a.sync()
        for mac in [a, b] {
            #expect(Set(mac.library.contents.siteRoutes.map(\.site)) == ["a.com", "b.com"], "\(mac.library.contents.siteRoutes.map(\.site))")
            #expect(mac.library.spaceNames == ["Home"])
            #expect(mac.library.contents.spaces[0].pinnedSplits?.count == 1)
        }
    }

    @Test func preferencesMeetKeyByKey() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal")], settings: ["ReaderSize": .int(16)]))
        #expect(b.library.settings["ReaderSize"] == .int(16))
        a.edit { $0.settings["ReaderSize"] = .int(20) }
        b.edit { $0.settings["DarkPages"] = .string("on"); $0.searchEngine = .duckDuckGo }
        a.sync(); b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.settings["ReaderSize"] == .int(20))
            #expect(mac.library.settings["DarkPages"] == .string("on"))
            #expect(mac.library.searchEngine == .duckDuckGo)
        }
        // Set back to its default on one Mac, it's unset on the other.
        a.edit { $0.settings["DarkPages"] = nil }
        a.sync(); b.sync()
        #expect(b.library.settings["DarkPages"] == nil)
    }

    @Test func onlyPreferencesTravelNeverWhatIsAboutThisMac() {
        let defaults = UserDefaults(suiteName: "SyncTests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        for (key, value) in ["ReaderSize": 18, "DownloadFolder": "/Users/me/Downloads", "BetaUpdates": true, "SUAutomaticallyUpdate": false,
                             "MiniWindowSize": "{300, 200}", "SidebarWidth": 260, "LaunchCount": 9, "DebugNoAutoplay": true, "MCPPort": 8000,
                             "AllowsAIApps": true, "TrustedCertificates": ["a": "b"], "SyncWithICloud": true, "AppleLanguages": ["de"]] as [String: Any] {
            defaults.set(value, forKey: key)
        }
        defaults.set(["example.com": "🙂", "other.com": "image:abc.png"], forKey: "SiteIcons")
        let read = SyncPreferences.read(from: defaults, profiles: [Profile.defaultID])
        #expect(read.keys.sorted() == ["ReaderSize", "SiteIcons"])
        #expect(read["SiteIcons"] == .dictionary(["example.com": .string("🙂")]))
        #expect(SyncPreferences.keys.isDisjoint(with: ["DownloadFolder", "BetaUpdates", "SUAutomaticallyUpdate", "SidebarWidth", "SidebarSize",
                                                       "CommandBarPosition", "MiniWindowSize", "MiniPlayerPlace", "SyncWithICloud", "MCPPort"]))
        // A profile's own choice travels under its profile.
        let work = UUID()
        #expect(SyncPreferences.owner("ExtensionsOffSites.\(work.uuidString)") == (true, work))
        #expect(SyncPreferences.owner("PasswordsManager").carried == false)
    }

    @Test func permissionsPasswordFillingAndCookieClearingStayOnEachMac() {
        let work = UUID()
        for key in ["SitePermissions", "SitePermissionActions", "SiteAsksBeforeDownloads", "JavaScriptOnSites",
                    "PasswordsAutofill.\(work.uuidString)", "PasswordsOfferToSave.\(work.uuidString)",
                    "CookiesClearOnQuit.\(work.uuidString)", "CookiesKeptSites.\(work.uuidString)", "CookiesClearOnQuit"] {
            #expect(!SyncPreferences.owner(key).carried, "\(key)")
        }
        // Blocking scripts on a site still travels; allowing them where they're off doesn't.
        #expect(SyncPreferences.owner("JavaScriptOffSites").carried)
    }

    @Test func theNewestAppearanceChoicesTravel() {
        for key in [SidebarView.pinnedTilesKey, "ShortFloatingSidebar", "ShowLinkAddressOnHover"] { #expect(SyncPreferences.owner(key).carried, "\(key)") }
    }

    // MARK: Account and settling

    @Test func anotherAccountIsNeverSyncedWithoutAsking() {
        #expect(ICloudSync.mayUse(account: "_abc", saved: nil))
        #expect(ICloudSync.mayUse(account: "_abc", saved: "_abc"))
        #expect(!ICloudSync.mayUse(account: "_xyz", saved: "_abc"))
    }

    @Test func aStateFileThatCouldntBeReadStillKnowsTheAccount() {
        // State.json unreadable: read as a fresh state, with the account kept beside it.
        let state = ICloudSync.stateAtLaunch(saved: SyncState(), libraryWasRead: true, account: "_abc")
        #expect(state.account == "_abc")
        #expect(!ICloudSync.mayUse(account: "_xyz", saved: state.account))
        #expect(ICloudSync.stateAtLaunch(saved: SyncState(), libraryWasRead: false, account: "_abc").account == "_abc")
    }

    @Test func onceSettledNothingMoreIsSent() {
        let inner = Sample.page("inner")
        let folder = BookmarkFolder(name: "F", bookmarkIDs: [inner.id])
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), inner], folders: [folder, BookmarkFolder(name: "Empty")])],
                                                favorites: [Sample.page("fav")], settings: ["ReaderSize": .int(16)]))
        b.sync(); a.sync()
        let sentA = a.sent, sentB = b.sent
        a.sync(); b.sync(); a.sync(); b.sync()
        a.session.localChanged(); b.session.localChanged()
        a.sync(); b.sync()
        #expect(a.sent == sentA && b.sent == sentB)
    }

    @Test func aKindOnlyANewerZigzagKnowsIsLeftAlone() {
        let cloud = FakeCloud()
        cloud.save(SyncUpload(name: "reminder.1", type: "Reminder", payload: Data(#"{"x":1}"#.utf8), modified: Date(), systemFields: nil))
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        a.sync()
        a.edit { $0.editSpace("Personal") { $0.bookmarks = [] } }
        a.sync()
        #expect(cloud.records["reminder.1"] != nil)
    }

    // MARK: Settings

    @Test func theStatusLineSaysWhatSyncIsDoing() {
        let now = Date()
        #expect(SyncSettingsRows.describe(.off, hasCopy: false, now: now).text.isEmpty)
        #expect(SyncSettingsRows.describe(.off, hasCopy: true, now: now).action != nil)
        #expect(SyncSettingsRows.describe(.synced(now.addingTimeInterval(-10)), hasCopy: true, now: now).text
                == String(localized: "Last synced just now", comment: "Status under Sync with iCloud in Settings › General: the last sync was less than a minute ago."))
        #expect(SyncSettingsRows.describe(.synced(now.addingTimeInterval(-120)), hasCopy: true, now: now).text.contains("2"))
        // Older than a day: the date and time it last synced.
        let old = now.addingTimeInterval(-3 * 86400)
        #expect(SyncSettingsRows.describe(.synced(old), hasCopy: true, now: now).text.contains(old.formatted(Date.FormatStyle(locale: Words.locale).day())))
        let signedOut = SyncSettingsRows.describe(.notSignedIn, hasCopy: true, now: now)
        #expect(signedOut.action == String(localized: "Open System Settings", comment: "Button beside “Not signed in to iCloud” in Settings › General: opens Apple Account in System Settings."))
        #expect(!SyncSettingsRows.describe(.full, hasCopy: true, now: now).text.isEmpty)
        // Off by default, with nothing under it.
        let settings = SettingsView(pane: .general)
        #expect(!settings.syncRows.toggle.isOn)
        #expect(!settings.syncRows.statusRow.isAvailable)
    }

    private func makeLine(_ waits: Waits) -> SyncStatusLine {
        let line = SyncStatusLine()
        line.schedule = { [waits] delay, work in
            waits.delays.append(delay)
            waits.pending = work
            return { [weak waits] in waits?.pending = nil }
        }
        return line
    }

    @Test func aQuickCatchUpDoesntSaySyncing() {
        let waits = Waits()
        let line = makeLine(waits)
        var changes = 0
        let before = Date(timeIntervalSince1970: 1_800_000_000), after = before + 30
        line.update(.synced(before), lastSynced: before)
        line.onChange = { changes += 1 }
        line.update(.syncing, lastSynced: before)
        #expect(line.status == .synced(before))
        line.update(.synced(after), lastSynced: after)
        #expect(line.status == .synced(after))
        #expect(waits.pending == nil && changes == 1)
        // At launch, the last sync shows while the first catch-up runs.
        let launched = makeLine(Waits())
        launched.update(.syncing, lastSynced: before)
        #expect(launched.status == .synced(before))
    }

    @Test func aSlowCatchUpAndTheFirstSyncSaySyncing() {
        let waits = Waits()
        let line = makeLine(waits)
        let before = Date(timeIntervalSince1970: 1_800_000_000)
        line.update(.synced(before), lastSynced: before)
        line.update(.syncing, lastSynced: before)
        #expect(waits.delays == [SyncStatusLine.delay] && SyncStatusLine.delay == 1.5)
        waits.runAll()
        #expect(line.status == .syncing)
        // The first sync, or turned on again: Syncing… at once.
        let first = makeLine(Waits())
        first.update(.syncing, lastSynced: nil)
        #expect(first.status == .syncing)
    }

    @Test func lastSyncedMovesAfterAnEmptyFetch() async throws {
        let (_, a, _) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let before = try #require(a.session.state.lastSynced)
        a.clock += 300
        try await ICloudSync.catchUp(a.session, through: a)
        #expect(a.saves.isEmpty && a.deletes.isEmpty)
        #expect(a.session.state.lastSynced == a.clock)
        #expect(ICloudSync.status(.synced(before), lastSynced: a.session.state.lastSynced) == .synced(a.clock))
        // Kept in the state, so it's there after a relaunch.
        let relaunched = try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(a.session.state))
        #expect(relaunched.lastSynced == a.clock)
    }

    @Test func errorsWinOverLastSynced() {
        let waits = Waits()
        let line = makeLine(waits)
        let before = Date(timeIntervalSince1970: 1_800_000_000)
        line.update(.synced(before), lastSynced: before)
        line.update(.offline, lastSynced: before)
        #expect(line.status == .offline)
        // A quick retry keeps saying so.
        line.update(.syncing, lastSynced: before)
        #expect(line.status == .offline)
        #expect(ICloudSync.status(.offline, lastSynced: before + 60) == .offline)
        let lastSynced = SyncSettingsRows.describe(.synced(before), hasCopy: true).text
        for status: ICloudSync.Status in [.offline, .notSignedIn, .otherAccount, .full, .failed("x"), .removalsHeld([.page: 2], .synced(before))] {
            #expect(SyncSettingsRows.describe(status, hasCopy: true).text != lastSynced)
        }
    }

    @Test func anUnrelatedDefaultsChangeSendsNothing() throws {
        let (_, a, _) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let defaults = try #require(UserDefaults(suiteName: "SyncTests.unrelated"))
        defer { defaults.removePersistentDomain(forName: "SyncTests.unrelated") }
        var carried = SyncPreferences.read(from: defaults, profiles: [])
        defaults.set("{{0, 0}, {800, 600}}", forKey: "NSWindow Frame main")
        #expect(!ICloudSync.carriedPreferencesChanged(&carried, now: SyncPreferences.read(from: defaults, profiles: [])))
        a.session.localChanged()
        #expect(a.saves.isEmpty && a.deletes.isEmpty)
        defaults.set(true, forKey: "ReduceMotion")
        #expect(ICloudSync.carriedPreferencesChanged(&carried, now: SyncPreferences.read(from: defaults, profiles: [])))
    }

    @Test func aBackupIsSavedBeforeTheFirstSync() throws {
        let url = try #require(ICloudSync.shared.backUp())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.deletingLastPathComponent().lastPathComponent == "Backups")
        guard case .success(let backup) = ZigzagBackup.read(url) else { Issue.record("the backup doesn't read"); return }
        #expect(backup.spaces.map(\.id) == Library.shared.spaces.map(\.id))
        // Every preference sync carries is in it.
        #expect(SyncPreferences.keys.isSubset(of: ZigzagBackup.settingKeys), "\(SyncPreferences.keys.subtracting(ZigzagBackup.settingKeys).sorted())")
        #expect(Set(SyncPreferences.profileKeys).isSubset(of: ZigzagBackup.profileSettingKeys))
    }

    @Test func withoutABackupSyncStaysOff() {
        let sync = ICloudSync.shared
        guard !sync.isOn else { return }
        defer { if sync.isOn { sync.turnOff() } }
        sync.turnOn(backingUp: { nil })
        #expect(!sync.isOn)
        #expect(sync.status == .backupFailed)
        #expect(!SyncSettingsRows.describe(.backupFailed, hasCopy: false).text.isEmpty)
    }

    /// With TEST_RUNNER_ZIGZAG_SYNC_SHOTS set to a folder: pictures of the row in each status and of its sheets.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZIGZAG_SYNC_SHOTS"] != nil)) func picturesOfTheRowAndItsSheets() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZIGZAG_SYNC_SHOTS"]!)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func save(_ view: NSView, _ rect: NSRect, _ name: String) {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
            view.cacheDisplay(in: rect, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        }
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            defer { window.close() }
            let settings = SettingsView(pane: .general)
            settings.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
            window.contentView?.addSubview(settings)
            let tooBig = SyncSettingsRows.everyTooBig.map { ($0.name, ICloudSync.Status.synced(Date()), true, true, $0.tooBig) }
            for (name, status, isOn, hasCopy, big) in SyncSettingsRows.everyStatus.map({ ($0.name, $0.status, $0.isOn, $0.hasCopy, SyncTooBig()) }) + tooBig {
                settings.syncRows.show(status, isOn: isOn, hasCopy: hasCopy, tooBig: big)
                settings.needsLayout = true
                settings.layoutSubtreeIfNeeded()
                let rows = settings.syncRows
                var rect = rows.row.convert(rows.row.bounds, to: settings)
                if !rows.statusRow.isHidden { rect = rect.union(rows.statusRow.convert(rows.statusRow.bounds, to: settings)) }
                save(settings, rect.insetBy(dx: -24, dy: -20).intersection(settings.bounds), "row-\(look)-\(name.replacingOccurrences(of: " ", with: "-"))")
            }
            settings.syncRows.show(.off, isOn: false, hasCopy: false)
            settings.needsLayout = true
            settings.layoutSubtreeIfNeeded()
            save(settings, settings.bounds, "general-\(look)")
            guard let host = window.contentView else { continue }
            for (name, sheet) in SyncSettingsRows.sheets {
                ConfirmSheet.show(in: host, title: sheet.title, message: sheet.message, confirmTitle: sheet.confirm, destructive: name == "remove") { _ in }
                for shown in host.subviews.compactMap({ $0 as? ConfirmSheet }) {
                    shown.alphaValue = 1
                    shown.layoutSubtreeIfNeeded()
                    save(host, host.bounds, "sheet-\(look)-\(name.replacingOccurrences(of: " ", with: "-"))")
                    shown.removeFromSuperview()
                }
            }
        }
    }

    @Test func aPreferenceTooBigForICloudStaysOnThisMac() {
        let big = SettingValue.data(Data(repeating: 65, count: 300_000))
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal")], settings: ["SiteBoosts": big, "ReaderSize": .int(18)]))
        a.sync()
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal")], settings: ["SiteBoosts": .data(Data("small".utf8))]), clock: a.clock)
        b.sync(); a.sync(); b.sync()
        // The rest of the settings travel; each Mac keeps its own styles.
        #expect(b.library.settings["ReaderSize"] == .int(18))
        #expect(a.library.settings["SiteBoosts"] == big)
        #expect(b.library.settings["SiteBoosts"] == .data(Data("small".utf8)))
        #expect((cloud.records[SyncName.settings]?.payload.count ?? 0) < SyncSession.largestPayload)
        let sentA = a.sent, sentB = b.sent
        a.session.localChanged(); b.session.localChanged()
        a.sync(); b.sync(); a.sync()
        #expect(a.sent == sentA && b.sent == sentB)
    }

    @Test func preferencesTooBigTogetherStillSyncTheRestAndSaySo() throws {
        // Each under the 200 KB a value may take, over 900 KB together.
        func sites(_ n: Int) -> [String] { (0..<n).map { "site-\($0)-with-a-long-name.example.com" } }
        let boosts = SettingValue.data(Data(repeating: 66, count: 140_000))
        let dark = SettingValue.array(sites(4_400).map { .string($0) })
        let icons = SettingValue.dictionary(Dictionary(uniqueKeysWithValues: sites(3_800).map { ($0, SettingValue.string("star")) }))
        let banners = SettingValue.array(sites(4_000).map { .string("banner-" + $0) })
        let zoom = SettingValue.dictionary(Dictionary(uniqueKeysWithValues: sites(4_000).map { ($0, SettingValue.double(1.25)) }))
        let big = ["SiteBoosts": boosts, "DarkPagesOnSites": dark, "SiteIcons": icons, "CookieBannersHandledSites": banners, "ZoomLevels": zoom]
        for value in big.values { #expect(!SyncPreferences.isTooBig(value)) }
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal")], settings: big.merging(["ReaderSize": .int(18)]) { a, _ in a }))
        a.sync()
        let own = big.mapValues { _ in SettingValue.array([.string("b.example")]) }
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal")], settings: own), clock: a.clock)
        b.sync(); a.sync(); b.sync()
        // The settings record fits, and what's in it arrives.
        let record = try #require(cloud.records[SyncName.settings])
        #expect(record.payload.count <= SyncSession.largestPayload)
        #expect(b.library.settings["ReaderSize"] == .int(18))
        // What didn't fit stays on A as it is, isn't replaced by B's, and A says so; B's own stays B's.
        let kept = a.session.tooBig.settings
        #expect(!kept.isEmpty && kept.isSubset(of: Set(big.keys)))
        for key in kept { #expect(a.library.settings[key] == big[key] && b.library.settings[key] == own[key], "\(key)") }
        for key in Set(big.keys).subtracting(kept) { #expect(b.library.settings[key] == big[key], "\(key)") }
        #expect(SyncSettingsRows.describe(.synced(a.clock), hasCopy: true, tooBig: a.session.tooBig).detail.isEmpty == false)
        #expect(SyncSettingsRows.describe(.synced(a.clock), hasCopy: true, tooBig: b.session.tooBig).detail.isEmpty)
        // Nothing is asked again and again, and later edits keep syncing.
        let sentA = a.sent
        a.session.localChanged(); a.sync()
        #expect(a.sent == sentA)
        a.edit { $0.settings["ReaderSize"] = .int(20) }
        a.sync(); b.sync()
        #expect(b.library.settings["ReaderSize"] == .int(20))
    }

    @Test func aRemovalsRecordTooBigKeepsItsNewestNotes() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        // Thousands removed lately, more than one record holds.
        let old = Dictionary(uniqueKeysWithValues: (0..<20_000).map { (SyncName.page(UUID()), a.clock - Double(20_000 - $0)) })
        a.session.updateState { $0.base[SyncName.removals] = SyncItem(.removals(SyncRemovals(names: old)), modified: a.clock) }
        let page = try #require(pageName(a, "b"))
        a.edit { $0.editSpace("Personal") { $0.bookmarks.removeAll { $0.url.lastPathComponent == "b" } } }
        a.sync(); b.sync()
        let record = try #require(cloud.records[SyncName.removals])
        #expect(record.payload.count <= SyncSession.largestPayload)
        guard case .removals(let removals) = SyncBody.decode(type: record.type, payload: record.payload) else { Issue.record("not removals"); return }
        #expect(removals.names[page] != nil)
        #expect(a.session.tooBig.isEmpty)
        #expect(b.library.urls(in: "Personal") == ["a"])
    }

    @Test func aRecordTooBigForICloudIsntSentAndStaysHere() {
        let huge = Bookmark(url: URL(string: "data:text/plain," + String(repeating: "a", count: 1_000_000))!, title: "Huge")
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a"), huge])]))
        a.sync()
        #expect(cloud.records[SyncName.page(huge.id)] == nil)
        #expect(cloud.records.keys.contains(where: { $0.hasPrefix("page.") }))
        let sent = a.sent
        a.sync(); a.session.localChanged(); a.sync()
        #expect(a.sent == sent)
        #expect(a.library.titles(in: "Personal") == ["a", "Huge"])
        // Said under the switch.
        #expect(a.session.tooBig.kinds == [.page: 1])
        #expect(!SyncSettingsRows.describe(.synced(a.clock), hasCopy: true, tooBig: a.session.tooBig).detail.isEmpty)
    }

    @Test func aThousandPinnedPagesSyncQuickly() {
        let pages = (0..<1000).map { Sample.page("p\($0)") }
        let start = Date()
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", pages)]))
        #expect(b.library.space(named: "Personal")?.bookmarks.count == 1000)
        let sent = a.sent
        a.edit { $0.editSpace("Personal") { $0.bookmarks[500].title = "Changed" } }
        a.sync()
        // One edit sends one record.
        #expect(a.sent == sent + 1)
        b.sync()
        #expect(b.library.space(named: "Personal")?.bookmarks[500].title == "Changed")
        #expect(Date().timeIntervalSince(start) < 20)
    }

    // MARK: Many removals at once

    private func manyPages() -> (FakeCloud, FakeMac, FakeMac) {
        twoMacs(Sample.library([Sample.space("Personal", (0..<40).map { Sample.page("p\($0)") })]))
    }

    /// Zigzag launched with `library` in Library.json.
    private func relaunch(_ mac: FakeMac, with library: SyncLibrary) {
        mac.library = library
        mac.session.checkAfterLaunch()
    }

    @Test func aLibraryPutBackFromAnOldCopyIsntSentAsRemovals() {
        let (cloud, a, b) = manyPages()
        let records = cloud.records.count
        // An old Library.json put back: 35 of 40 pages gone at once.
        var old = a.library
        old.editSpace("Personal") { $0.bookmarks.removeLast(35) }
        relaunch(a, with: old)
        #expect(a.session.state.heldRemovals == 35)
        #expect(a.saves.isEmpty && a.deletes.isEmpty)
        let shown = SyncSettingsRows.describe(.removalsHeld([.page: 35], .offline), hasCopy: true)
        #expect(shown.second != nil && shown.text.contains("35"))
        #expect(shown.detail.contains(SyncSettingsRows.describe(.offline, hasCopy: true).text))
        #expect(SyncSettingsRows.removeEverywhereSheet([.page: 35]).title.contains("35"))
        // A page pinned since goes up at once; the removals don't.
        a.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("new")) } }
        a.sync(); b.sync()
        #expect(cloud.records.count == records + 1)
        #expect(b.library.urls(in: "Personal").count == 41)
        // Restore: iCloud's pages come back.
        a.session.bringBackHeld()
        a.sync(); b.sync()
        #expect(a.session.state.heldRemovals == nil)
        #expect(a.library.urls(in: "Personal").count == 41 && a.library.urls(in: "Personal").contains("new"))
        #expect(b.library.urls(in: "Personal").count == 41)
    }

    @Test func manyRemovalsSentWhenAsked() {
        let (_, a, b) = manyPages()
        var old = a.library
        old.editSpace("Personal") { $0.bookmarks.removeLast(35) }
        relaunch(a, with: old)
        a.session.sendHeld()
        a.sync(); b.sync()
        #expect(b.library.urls(in: "Personal").count == 5)
        #expect(a.library.urls(in: "Personal").count == 5)
    }

    @Test func restoringAnOldCopyTakesICloudsVersionOfEverythingElse() {
        let (_, a, b) = manyPages()
        let old = a.library
        // Since then: p1 renamed and p2 removed by hand, on B.
        b.edit { $0.editSpace("Personal") { $0.bookmarks[1].title = "Renamed"; $0.bookmarks.remove(at: 2) } }
        b.sync(); a.sync()
        // A's Library.json put back from the old copy, with 35 of its pages lost too.
        var rolled = old
        rolled.editSpace("Personal") { $0.bookmarks.removeLast(35) }
        a.clock += 100
        relaunch(a, with: rolled)
        #expect(a.session.state.heldRemovals != nil)
        a.session.bringBackHeld()
        a.sync(); b.sync(); a.sync()
        for mac in [a, b] {
            #expect(mac.library.titles(in: "Personal")[1] == "Renamed", "stale title sent")
            #expect(!mac.library.urls(in: "Personal").contains("p2"), "deleted pin resurrected")
            #expect(mac.library.urls(in: "Personal").count == 39)
        }
    }

    @Test func removingASpaceAndItsPinsByHandIsSentAtOnce() {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", (0..<20).map { Sample.page("p\($0)") }),
                                                Sample.space("Work", (0..<15).map { Sample.page("w\($0)") })]))
        a.edit { $0.contents.spaces.removeAll { $0.name == "Work" } }
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "edited later" } }
        a.sync(); b.sync()
        #expect(a.session.state.heldRemovals == nil)
        #expect(b.library.spaceNames == ["Personal"])
        #expect(b.library.titles(in: "Personal").first == "edited later")
    }

    @Test func anEditWhileRemovalsAreHeldKeepsItsOwnTime() {
        let (_, a, b) = manyPages()
        var old = a.library
        old.editSpace("Personal") { $0.bookmarks.removeLast(35) }
        relaunch(a, with: old)
        #expect(a.session.state.heldRemovals != nil)
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "older, from A" } }
        b.clock = a.clock + 60
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "newer, from B" } }
        b.sync()
        a.clock = b.clock + 3600
        a.sync()
        a.session.sendHeld()
        a.sync(); b.sync()
        #expect(b.library.titles(in: "Personal").first == "newer, from B")
        #expect(a.library.titles(in: "Personal").first == "newer, from B")
    }

    @Test func aLibraryOlderThanTheOneLastSyncedSendsNothing() {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        let old = a.library
        a.host.libraryStamp = Date(timeIntervalSince1970: 1_000)
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "Since" } }
        a.host.libraryStamp = Date(timeIntervalSince1970: 2_000)
        a.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("c")) } }
        a.sync(); b.sync()
        let records = cloud.records
        // Library.json put back from a copy saved before the last sync: one pin fewer, an old title.
        a.host.libraryStamp = Date(timeIntervalSince1970: 1_500)
        var told = false
        a.session.onTookICloud = { told = true }
        relaunch(a, with: old)
        #expect(told)
        #expect(a.saves.isEmpty && a.deletes.isEmpty)
        a.sync(); b.sync()
        #expect(cloud.records.mapValues(\.tag) == records.mapValues(\.tag))
        #expect(a.library.titles(in: "Personal") == ["Since", "b", "c"])
    }

    @Test func aMissingProfilesFileIsUnreadableNotEveryProfileRemoved() {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        let (_, a, _) = twoMacs(Sample.library([Sample.space("Personal")], directory: directory))
        #expect(a.session.state.base[SyncName.profile(work.id)] != nil)
        #expect(!ICloudSync.libraryWasRead(true, profilesFile: false, saved: a.session.state))
        #expect(ICloudSync.libraryWasRead(true, profilesFile: true, saved: a.session.state))
        // One profile only: there was never a file.
        let (_, single, _) = twoMacs(Sample.library([Sample.space("Personal")]))
        #expect(ICloudSync.libraryWasRead(true, profilesFile: false, saved: single.session.state))
    }

    // MARK: Out of order

    @Test func aPageArrivingBeforeItsSpaceWaitsForIt() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        b.edit { $0.contents.spaces.append(Sample.space("New", [Sample.page("n")])) }
        // Parents go first.
        #expect(b.saves.map { $0.prefix { $0 != "." } } == ["space", "page"])
        b.sync()
        let page = try #require(cloud.records.keys.first { name in
            name.hasPrefix("page.") && cloud.remote(name).map { String(decoding: $0.payload, as: UTF8.self).contains("/n") } == true
        })
        let before = cloud.records[page]?.payload
        // A reads the page before its space.
        a.session.fetched([try #require(cloud.remote(page))], deleted: [])
        a.session.fetchFinished()
        #expect(a.library.spaceNames == ["Personal"] && a.library.urls(in: "Personal") == ["a"])
        #expect(a.saves.isEmpty && a.deletes.isEmpty)
        a.sync()
        #expect(a.library.spaceNames == ["Personal", "New"] && a.library.urls(in: "New") == ["n"])
        #expect(cloud.records[page]?.payload == before)
    }

    @Test func whatsInsideARecordANewerZigzagWroteIsLeftAlone() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let space = try #require(a.library.contents.spaces.first?.id)
        let folder = UUID(), page = UUID()
        // A folder this version can't read, and a page in it.
        cloud.save(SyncUpload(name: SyncName.folder(folder), type: SyncBody.folderType, payload: Data(#"{"name":"New","space":7}"#.utf8), modified: Date(), systemFields: nil))
        let inside = SyncBody.page(SyncPage(url: URL(string: "https://example.com/inside")!, title: "Inside", icon: nil, space: space, parent: folder, position: "n")).encoded()
        cloud.save(SyncUpload(name: SyncName.page(page), type: SyncBody.pageType, payload: inside, modified: Date(), systemFields: nil))
        let sent = a.sent + b.sent
        a.sync(); b.sync(); a.session.localChanged(); a.sync()
        #expect(a.library.urls(in: "Personal") == ["a"])
        #expect(cloud.records[SyncName.page(page)]?.payload == inside)
        #expect(a.sent + b.sent == sent)
    }

    @Test func preferencesThisVersionDoesntKnowAreKeptAsTheyAre() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal")], settings: ["ReaderSize": .int(16)]))
        let future = SyncSettings.Entry(value: .string("on"), modified: Date(timeIntervalSince1970: 1_700_000_000))
        let elsewhere = "\(ProfileKey.extensionsOffSites.rawValue).\(UUID().uuidString)"
        guard case .settings(var settings) = SyncBody.decode(type: SyncBody.settingsType, payload: try #require(cloud.records[SyncName.settings]).payload) else {
            Issue.record("no settings"); return
        }
        settings.values["FutureSetting"] = future
        settings.values[elsewhere] = future
        let tag = try #require(cloud.remote(SyncName.settings)).systemFields
        cloud.save(SyncUpload(name: SyncName.settings, type: SyncBody.settingsType, payload: SyncBody.settings(settings).encoded(), modified: Date(), systemFields: tag))
        a.sync()
        a.edit { $0.settings["ReaderSize"] = .int(20) }
        a.sync()
        guard case .settings(let after) = SyncBody.decode(type: SyncBody.settingsType, payload: try #require(cloud.records[SyncName.settings]).payload) else {
            Issue.record("no settings"); return
        }
        #expect(after.values["ReaderSize"]?.value == .int(20))
        #expect(after.values["FutureSetting"] == future)
        #expect(after.values[elsewhere] == future)
    }

    // MARK: Connecting

    /// The state as State.json keeps it.
    private func saved(_ state: SyncState) throws -> SyncState {
        try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state))
    }

    @Test func whatAFetchBroughtBeforeAQuitArrivesAfterIt() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        b.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("new")) } }
        b.sync()
        // A's fetch brings B's page and the server's token is saved, then Zigzag quits before the fetch ends.
        let changes = cloud.changes(since: 0)
        a.session.fetched(changes.records, deleted: changes.deleted)
        let relaunched = FakeMac(cloud, a.library, clock: b.clock, state: try saved(a.session.state))
        relaunched.session.fetchFinished()
        #expect(relaunched.library.urls(in: "Personal") == ["a", "new"])
    }


    @Test func aMacStartedAfterItsFirstSyncFetchesWhatChangedWhileItWasAway() async throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        // A quits; B pins a page meanwhile.
        let saved = a.session.state
        b.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("new")) } }
        b.sync()
        #expect(saved.merged && cloud.records.count > saved.serverPayloads.count)
        let relaunched = FakeMac(cloud, a.library, clock: b.clock, state: saved)
        try await ICloudSync.catchUp(relaunched.session, through: relaunched)
        #expect(relaunched.library.urls(in: "Personal") == ["a", "new"])
        #expect(relaunched.session.state.serverPayloads.count == cloud.records.count)
    }

    @Test func aFirstConnectionMergesThenSends() async throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        var first: Bool?
        try await ICloudSync.catchUp(a.session, through: a, fetched: { first = $0 })
        #expect(first == true)
        #expect(a.session.state.merged)
        #expect(!cloud.records.isEmpty && a.saves.isEmpty)
    }

    @Test func editsMadeBeforeConnectingAreSentOnceConnected() async throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        // Offline at launch, or before connecting: no server to queue for.
        a.session.server = nil
        a.edit { $0.editSpace("Personal") { $0.bookmarks.removeFirst(); $0.bookmarks.append(Sample.page("c")) } }
        a.session.server = a
        #expect(a.saves.isEmpty && a.deletes.isEmpty)
        try await ICloudSync.catchUp(a.session, through: a)
        b.sync()
        #expect(b.library.urls(in: "Personal") == ["b", "c"])
        #expect(cloud.records.count == a.session.state.base.count)
    }

    @Test func aRemovalOfWhatsAlreadyGoneIsntAskedAgain() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        let page = try #require(a.session.state.base.keys.first { $0.hasPrefix("page.") && a.session.state.base[$0].map { String(decoding: $0.payload, as: UTF8.self).contains("/b") } == true })
        // Both remove it; B's removal reaches iCloud first.
        b.online = false
        a.edit { $0.editSpace("Personal") { $0.bookmarks.removeAll { $0.url.lastPathComponent == "b" } } }
        b.edit { $0.editSpace("Personal") { $0.bookmarks.removeAll { $0.url.lastPathComponent == "b" } } }
        a.sync()
        b.online = true
        b.send()
        #expect(b.session.state.serverPayloads[page] == nil)
        b.session.requeue()
        #expect(b.deletes.isEmpty)
        #expect(cloud.records[page] == nil)
    }

    @Test func aConflictWithoutTheServersVersionIsFetchedThenSentAgain() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let page = try #require(a.session.state.base.keys.first { $0.hasPrefix("page.") })
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "B" } }
        b.sync()
        a.clock += 10
        a.edit { $0.contents.spaces[0].bookmarks[0].title = "A" }
        var fetched = false
        a.session.onNeedsFetch = { fetched = true }
        // iCloud refuses A's save as stale, without sending its own version.
        a.session.saveFailed(page, .conflictUnread)
        #expect(fetched && a.session.state.unsent.contains(page))
        a.fetch()
        a.session.requeue()
        a.send()
        b.sync()
        #expect(cloud.remote(page).map { String(decoding: $0.payload, as: UTF8.self).contains("\"title\":\"A\"") } == true)
        #expect(b.library.titles(in: "Personal") == ["A"])
    }

    @Test func aRecordFetchedTwiceOrLateChangesNothing() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let old = try #require(cloud.remote(cloud.records.keys.first { $0.hasPrefix("page.") }!))
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "Renamed" } }
        b.sync()
        let new = try #require(cloud.remote(old.name))
        // The same record twice, then the older copy from a fetch that crossed this one.
        for record in [new, new, old] {
            a.session.fetched([record], deleted: [])
            a.session.fetchFinished()
        }
        #expect(a.library.titles(in: "Personal") == ["Renamed"])
        #expect(a.session.state.unsent.isEmpty && a.saves.isEmpty)
        let sent = a.sent
        a.sync()
        #expect(a.sent == sent)
    }

    @Test func aSaveFindingTheZoneGoneNeverMakesItAgain() {
        let (cloud, a, _) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        var removed = false
        a.session.onZoneGone = { removed = true }
        cloud.removeZone()
        a.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("b")) } }
        a.sync()
        #expect(removed)
        #expect(a.saves.isEmpty && cloud.records.isEmpty)
    }

    @Test func aResetASaveFindsFirstIsMergedAgainNotTurnedOff() {
        // Gone by the user's hand (iCloud's data deleted in System Settings): removed. Gone while off here: merged afresh.
        // Otherwise a reset and a removal elsewhere both leave the zone not found, and the database's changes say which.
        #expect(ICloudSync.zoneGone(userDeleted: true, resumed: false) == .removed)
        #expect(ICloudSync.zoneGone(userDeleted: false, resumed: true) == .reset)
        #expect(ICloudSync.zoneGone(userDeleted: false, resumed: false) == .askWhy)
        #expect(ICloudSync.isReset(.encryptedDataReset))
        #expect(!ICloudSync.isReset(.deleted) && !ICloudSync.isReset(.purged) && !ICloudSync.isReset(nil))
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        // iCloud's copy is reset (its keys), and A's save finds the zone gone before any fetch does.
        cloud.removeZone()
        var asked = 0
        a.session.onZoneGone = { asked += 1 }
        a.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("c")) } }
        a.sync()
        // It asks why before doing anything; nothing here is lost or turned off meanwhile.
        #expect(asked > 0 && a.session.state.merged)
        #expect(a.library.urls(in: "Personal") == ["a", "b", "c"])
        // A reset: merged again as a first sync, with nothing twice.
        a.session.startOver()
        cloud.makeZoneAgain()
        a.sync()
        b.session.startOver()
        b.sync(); a.sync()
        for mac in [a, b] { #expect(mac.library.urls(in: "Personal") == ["a", "b", "c"]) }
        #expect(cloud.records.keys.filter { $0.hasPrefix("page.") }.count == 3)
    }

    @Test func aFirstSyncIntoAnICloudWithoutTheZoneMergesWithNothing() async throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        a.zoneMissing = true
        try await ICloudSync.catchUp(a.session, through: a)
        #expect(a.session.state.merged)
        #expect(!cloud.records.isEmpty)
    }

    @Test func aZoneRemovedAfterTheFirstSyncIsRemovedElsewhereNotTriedAgain() async {
        let (_, a, _) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        a.zoneMissing = true
        await #expect(throws: CKError.self) { try await ICloudSync.catchUp(a.session, through: a) }
        let gone = CKError(.zoneNotFound)
        #expect(ICloudSync.isZoneGone(gone) && ICloudSync.isZoneGone(CKError(.userDeletedZone)))
        #expect(ICloudSync.isZoneGone(CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [ICloudSync.zoneID: gone]])))
        #expect(!ICloudSync.isZoneGone(CKError(.serverRejectedRequest)))
        // Handled as removed from iCloud, never as an error to wait out.
        #expect(!SyncRetry.isPermanent(gone))
    }

    @Test func onlyZigzagsOwnPushesFromICloudFetch() {
        let push: [String: Any] = ["aps": ["content-available": 1],
                                   "ck": ["ce": 2, "cid": ICloudSync.containerID, "nid": "1", "met": ["dbs": 1, "sid": "s"]]]
        #expect(ICloudSync.isOurPush(push))
        var other = push
        other["ck"] = ["ce": 2, "cid": "iCloud.example.other", "nid": "1", "met": ["dbs": 1, "sid": "s"]]
        #expect(!ICloudSync.isOurPush(other))
        #expect(!ICloudSync.isOurPush(["aps": ["alert": "Hi"]]))
    }

    // MARK: Trying again

    /// A retry whose waits are noted and run by hand.
    private final class Waits {
        var delays: [TimeInterval] = []
        var pending: (() -> Void)?
        func runAll() { while let work = pending { pending = nil; work() } }
    }

    private func makeRetry(_ waits: Waits) -> SyncRetry {
        let retry = SyncRetry()
        retry.jitter = { 1 }
        retry.schedule = { [waits] delay, work in
            waits.delays.append(delay)
            waits.pending = work
            return { [weak waits] in waits?.pending = nil }
        }
        return retry
    }

    @Test func aFirstSyncICloudRefusesIsTriedAgainUntilItGoesThrough() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        a.failing = 4
        let waits = Waits()
        let retry = makeRetry(waits)
        retry.onRetry = {
            do { try a.trySync(); retry.succeeded() } catch { retry.failed(error) }
        }
        retry.onRetry?()
        #expect(!a.session.state.merged)
        #expect(retry.isWaiting)
        waits.runAll()
        #expect(waits.delays == [30, 60, 120, 240])
        #expect(a.session.state.merged)
        #expect(!cloud.records.isEmpty)
        #expect(retry.failures == 0 && !retry.isWaiting)
    }

    @Test func theWaitDoublesUpToHalfAnHourAndIsNeverSoonerThanICloudAsks() {
        #expect((1...8).map { SyncRetry.delay(afterFailures: $0) } == [30, 60, 120, 240, 480, 960, 1800, 1800])
        #expect(SyncRetry.delay(afterFailures: 1000) == 1800)
        #expect(SyncRetry.delay(afterFailures: 1, jitter: 0.8) == 24)
        #expect(SyncRetry.delay(afterFailures: 1, retryAfter: 300) == 300)
        #expect(SyncRetry.delay(afterFailures: 7, retryAfter: 300) == 1800)
        let waits = Waits()
        let retry = makeRetry(waits)
        retry.failed(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 600.0)]))
        #expect(waits.delays == [600])
    }

    @Test func iCloudRefusingOrLosingARequestShowsItTriesAgain() {
        for code in [CKError.Code.serverRejectedRequest, .internalError, .serverResponseLost, .networkFailure, .serviceUnavailable] {
            #expect(ICloudSync.status(for: CKError(code)) == .offline)
            #expect(!SyncRetry.isPermanent(CKError(code)))
        }
        #expect(SyncSettingsRows.describe(.offline, hasCopy: true).text
                == String(localized: "Can’t reach iCloud. Zigzag tries again.", comment: "Status under Sync with iCloud in Settings › General: no connection, or iCloud is busy."))
    }

    @Test func anErrorWaitingWontFixWaitsForTheAccountOrNetwork() {
        let waits = Waits()
        let retry = makeRetry(waits)
        for code in [CKError.Code.notAuthenticated, .managedAccountRestricted, .incompatibleVersion, .badContainer] {
            #expect(SyncRetry.isPermanent(CKError(code)))
            #expect(retry.failed(CKError(code)) == nil)
            #expect(!retry.isWaiting && retry.isStopped)
        }
        #expect(waits.delays.isEmpty)
        #expect(ICloudSync.status(for: CKError(.notAuthenticated)) == .notSignedIn)
        #expect(ICloudSync.status(for: CKError(.quotaExceeded)) == .full)
        #expect(ICloudSync.status(for: CKError(.managedAccountRestricted)) == .restricted)
        // The network coming back tries once more.
        retry.soon()
        #expect(waits.delays == [0])
    }

    @Test func aFullICloudIsTriedAgainWithTheUsualWaits() {
        let waits = Waits()
        let retry = makeRetry(waits)
        #expect(!SyncRetry.isPermanent(CKError(.quotaExceeded)))
        retry.failed(CKError(.quotaExceeded))
        retry.failed(CKError(.quotaExceeded))
        #expect(waits.delays == [30, 60])
        #expect(ICloudSync.status(for: CKError(.quotaExceeded)) == .full)
    }

    @Test func theNetworkComingBackTriesAtOnceButNotInALoop() {
        let waits = Waits()
        let retry = makeRetry(waits)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// How far ahead of the real time this Mac's clock runs.
    var skew: TimeInterval = 0
        retry.now = { clock }
        var tries = 0
        retry.onRetry = { tries += 1; retry.failed(CKError(.networkUnavailable)) }
        // Nothing failed: nothing to try.
        retry.soon()
        #expect(waits.delays.isEmpty)
        retry.failed(CKError(.networkUnavailable))
        retry.failed(CKError(.networkUnavailable))
        #expect(waits.delays == [30, 60])
        retry.soon()
        #expect(waits.delays.last == 0)
        waits.pending?()
        #expect(tries == 1)
        // The waits go on from where they were.
        #expect(waits.delays.last == 120)
        // Back again two seconds after a try: the rest of the five seconds first.
        clock += 2
        retry.soon()
        #expect(waits.delays.last == 3)
        retry.reset()
        #expect(!retry.isWaiting && retry.failures == 0)
        retry.soon()
        #expect(waits.delays.last == 3)
    }

    @Test func turningSyncOffStopsTryingAgain() {
        let sync = ICloudSync.shared
        guard !sync.isOn else { return }
        sync.retry.failed(CKError(.networkUnavailable))
        #expect(sync.retry.isWaiting)
        sync.turnOff()
        #expect(!sync.retry.isWaiting && sync.retry.failures == 0)
    }
}

// MARK: - Found in review

extension SyncTests {
    @Test func aFetchStillOnItsWayWhenSyncIsTurnedOffChangesNothing() {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        b.edit { $0.editSpace("Personal") { $0.bookmarks.append(Sample.page("new")) } }
        b.sync()
        // Sync turned off on A while its fetch is out.
        a.session.close()
        let changes = cloud.changes(since: 0)
        a.session.fetched(changes.records, deleted: changes.deleted)
        a.session.fetchFinished()
        a.session.localChanged()
        #expect(a.library.urls(in: "Personal") == ["a"])
        #expect(a.saves.isEmpty && a.deletes.isEmpty)
    }

    private func pageName(_ mac: FakeMac, _ path: String) -> String? {
        mac.session.state.base.keys.first { $0.hasPrefix("page.") && mac.session.state.base[$0].map { String(decoding: $0.payload, as: UTF8.self).contains("/\(path)\"") } == true }
    }

    @Test func aLateRemovalFromAFetchThatCrossedANewerOneIsIgnored() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        let name = try #require(pageName(a, "b"))
        let start = cloud.changes(since: 0).token
        let kept = b.library.space(named: "Personal")!.bookmarks[1]
        // B removes the pin and puts it back (undo).
        b.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 1) } }
        b.sync()
        let deletion = cloud.changes(since: start)
        b.edit { $0.editSpace("Personal") { $0.bookmarks.append(kept) } }
        b.sync()
        // A fetch that started earlier brings the removal after A's own fetch brought the pin back.
        let earlier = a.clock
        a.clock += 5
        a.fetch()
        a.session.fetched([], deleted: deletion.deleted, startedAt: earlier)
        a.session.fetchFinished()
        a.sync()
        #expect(a.library.urls(in: "Personal") == ["a", "b"])
        #expect(cloud.records[name] != nil)
    }

    @Test func aFolderMovedToAnotherSpaceAndReadInPartsKeepsItsPages() throws {
        var folder = BookmarkFolder(name: "F")
        let f1 = Sample.page("f1"), f2 = Sample.page("f2")
        folder.bookmarkIDs = [f1.id, f2.id]
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("One", [Sample.page("o"), f1, f2], folders: [folder]), Sample.space("Two", [Sample.page("t")])]))
        #expect(b.library.space(named: "One")?.folders?.count == 1)
        let before = cloud.changes(since: 0).token
        a.edit { lib in
            var moved = lib.space(named: "One")!.folders![0]
            let pages = lib.space(named: "One")!.bookmarks.filter { moved.bookmarkIDs.contains($0.id) }
            lib.editSpace("One") { $0.folders = []; $0.bookmarks.removeAll { moved.bookmarkIDs.contains($0.id) } }
            moved.parentID = nil
            lib.editSpace("Two") { $0.folders = [moved]; $0.bookmarks.append(contentsOf: pages) }
        }
        a.sync()
        let changes = cloud.changes(since: before)
        // B reads the folder first, its pages in a later fetch.
        b.clock = a.clock + 5
        b.session.fetched(changes.records.filter { $0.name.hasPrefix("folder.") }, deleted: [])
        b.session.fetchFinished()
        b.clock += 1
        b.session.fetched(changes.records.filter { !$0.name.hasPrefix("folder.") }, deleted: changes.deleted)
        b.session.fetchFinished()
        b.sync(); a.sync(); b.sync()
        for (n, mac) in [("a", a), ("b", b)] {
            #expect(mac.library.urls(in: "One") == ["o"], "\(n): pages left behind in the old space")
            #expect(mac.library.space(named: "Two")?.folders?.first?.bookmarkIDs.count == 2, "\(n)")
        }
    }

    @Test func aSplitReadBeforeItsPagesIsKept() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let before = cloud.changes(since: 0).token
        let left = Sample.page("left"), right = Sample.page("right")
        a.edit { $0.editSpace("Personal") { $0.bookmarks += [left, right]; $0.pinnedSplits = [PinnedSplit(left: left.id, right: right.id)] } }
        a.sync()
        let changes = cloud.changes(since: before)
        // B reads the space, with its new split, before the split's two pages.
        b.clock = a.clock + 5
        b.session.fetched(changes.records.filter { $0.name.hasPrefix("space.") }, deleted: [])
        b.session.fetchFinished()
        b.session.fetched(changes.records.filter { !$0.name.hasPrefix("space.") }, deleted: [])
        b.session.fetchFinished()
        b.sync(); a.sync(); b.sync()
        #expect(a.library.space(named: "Personal")?.pinnedSplits?.count == 1, "split lost on A")
        #expect(b.library.space(named: "Personal")?.pinnedSplits?.count == 1, "split lost on B")
    }

    @Test func aProfileRemovedElsewhereAndReadInPartsKeepsItsSpace() throws {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        let office = Sample.space("Office", [Sample.page("jira")])
        directory.assign(space: office.id, to: work.id)
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal"), office], directory: directory))
        let before = cloud.changes(since: 0).token
        a.edit { lib in var d = lib.contents.directory; d.remove(work.id); lib.contents.directory = d }
        a.sync()
        let changes = cloud.changes(since: before)
        // B reads the space's move to the first profile, then the profile's removal.
        b.session.fetched(changes.records, deleted: [])
        b.session.fetchFinished()
        b.session.fetched([], deleted: changes.deleted)
        b.session.fetchFinished()
        b.sync()
        let dir = b.library.contents.directory
        #expect(dir.profile(work.id) != nil)
        #expect(b.library.space(named: "Office").map { dir.profileID(ofSpace: $0.id) } == work.id)
    }

    @Test func aFavoriteRemovedOnPurposeDoesntComeBackWithItsProfileLater() {
        var directory = ProfileDirectory()
        let work = directory.add(name: "Work")
        let chat = Sample.page("chat"), mail = Sample.page("mail")
        directory.assign(favorite: chat.id, to: work.id)
        directory.assign(favorite: mail.id, to: work.id)
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal")], favorites: [chat, mail], directory: directory))
        // The favorite removed on purpose, and synced; days later the profile.
        a.edit { $0.contents.favorites.removeAll { $0.id == chat.id } }
        a.sync(); b.sync()
        a.edit { $0.editSpace("Personal") { $0.name = "Home" } }
        a.sync(); b.sync()
        a.edit { lib in
            var d = lib.contents.directory
            d.remove(work.id)
            lib.contents.directory = d
            lib.contents.favorites.removeAll { $0.id == mail.id }
        }
        a.sync(); b.sync()
        #expect(b.library.contents.directory.profile(work.id) != nil)
        #expect(b.library.contents.favorites.map(\.id) == [mail.id])
    }

    @Test func twoFirstSyncsAtOnceAgreeHoweverLateOneReads() {
        var diverged = 0
        for _ in 0..<12 {
            let cloud = FakeCloud()
            let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x")])]))
            let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("y")])]))
            a.fetch(); b.fetch()
            a.send(); b.send()
            a.sync()
            // B reads A's copies only hours later.
            b.clock += 7200
            b.sync(); a.sync(); b.sync(); a.sync()
            b.edit { $0.contents.spaces[$0.contents.spaces.count - 1].bookmarks.append(Sample.page("later")) }
            b.sync(); a.sync()
            let aURLs = a.library.contents.spaces.flatMap(\.bookmarks).map(\.url.lastPathComponent).sorted()
            let bURLs = b.library.contents.spaces.flatMap(\.bookmarks).map(\.url.lastPathComponent).sorted()
            if aURLs != bURLs || a.library.spaceNames != b.library.spaceNames || a.library.spaceNames != ["Personal"] || aURLs != ["later", "x", "y"] {
                diverged += 1
            }
        }
        #expect(diverged == 0, "\(diverged) of 12 diverged")
    }

    @Test func aSecondMacJoiningNormallyKeepsItsOwnDuplicatePins() {
        var bad = 0
        for _ in 0..<12 {
            let cloud = FakeCloud()
            let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x", "mine")])]))
            a.sync()
            // B joins minutes later with two pins of one address (two accounts on one site).
            let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x", "account 1"), Sample.page("x", "account 2")])]), clock: a.clock + 300)
            b.sync()
            a.clock += 300
            a.sync(); b.sync(); a.sync(); b.sync()
            if a.library.titles(in: "Personal").count != 2 || b.library.titles(in: "Personal").count != 2 { bad += 1 }
        }
        #expect(bad == 0, "\(bad) of 12 lost a pin or diverged")
    }

    @Test func aRemovalAfterThisMacsOwnSaveIsntTakenForStale() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        let staleStart = a.clock
        a.clock += 60
        a.edit { $0.editSpace("Personal") { $0.bookmarks[1].title = "edited on A" } }
        a.sync(); b.sync()
        let before = cloud.changes(since: 0).token
        b.clock = a.clock + 3600
        b.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 1) } }
        b.sync()
        let removal = cloud.changes(since: before)
        // A fetch that started before A's own save brings B's later removal.
        a.clock = b.clock + 10
        a.session.fetched([], deleted: removal.deleted, startedAt: staleStart)
        a.session.fetchFinished()
        #expect(a.library.urls(in: "Personal") == ["a"])
    }

    @Test func aClockOnceAheadDoesntMakeLaterLaunchesRollbacks() throws {
        let (cloud, a, _) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        // The clock a day ahead once, then set right.
        a.host.libraryStamp = a.clock.addingTimeInterval(86400)
        a.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "while ahead" } }
        a.host.libraryStamp = a.clock
        a.clock += 1
        a.library.editSpace("Personal") { $0.bookmarks.append(Sample.page("just before quit")) }
        a.host.libraryStamp = a.clock
        let again = FakeMac(cloud, a.library, clock: a.clock + 60, state: try saved(a.session.state))
        again.host.libraryStamp = a.clock
        again.session.checkAfterLaunch()
        again.sync()
        #expect(again.library.urls(in: "Personal") == ["a", "just before quit"])
    }

    @Test func anEditFoundAtLaunchCountsFromWhenItWasMade() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        // Edited on A, and Zigzag quit before sync read it; Library.json saved then.
        a.clock += 1
        a.library.editSpace("Personal") { $0.bookmarks[0].title = "A, Monday" }
        let monday = a.clock
        let quit = try saved(a.session.state)
        b.clock = a.clock + 3600
        b.edit { $0.editSpace("Personal") { $0.bookmarks[0].title = "B, Tuesday" } }
        b.sync()
        let again = FakeMac(cloud, a.library, clock: b.clock + 86400, state: quit)
        again.host.libraryStamp = monday
        again.session.checkAfterLaunch()
        again.sync(); b.sync()
        #expect(again.library.titles(in: "Personal") == ["B, Tuesday"])
        #expect(b.library.titles(in: "Personal") == ["B, Tuesday"])
    }

    @Test func turningOnAfterTidyingUpWhileOffKeepsNewPinsAndRenames() throws {
        let (cloud, a, b) = manyPages()
        let off = try saved(ICloudSync.stateTurningOff(b.session.state))
        // While off: 15 of 40 pins removed, one renamed, two new ones pinned.
        var library = b.library
        library.editSpace("Personal") { s in
            s.bookmarks.removeLast(15)
            s.bookmarks[0].title = "renamed while off"
            s.bookmarks.append(contentsOf: [Sample.page("new 1"), Sample.page("new 2")])
        }
        let again = FakeMac(cloud, library, clock: b.clock + 86400, state: ICloudSync.stateTurningOn(saved: off))
        again.session.checkAfterLaunch()
        #expect(again.session.state.heldRemovals == 15)
        again.sync(); a.sync()
        let urls = again.library.urls(in: "Personal")
        #expect(urls.contains("new 1") && urls.contains("new 2"))
        #expect(again.library.titles(in: "Personal").first == "renamed while off")
        #expect(a.library.urls(in: "Personal").contains("new 1"))
        #expect(a.library.urls(in: "Personal").count == 42)
    }

    @Test func aHeldLaunchKeepsAPinPinnedJustBeforeQuit() throws {
        let (cloud, a, b) = manyPages()
        // A pin removed elsewhere since, still in an old copy.
        let gone = a.library.space(named: "Personal")!.bookmarks[3]
        b.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 3) } }
        b.sync(); a.sync()
        a.clock += 1
        a.library.editSpace("Personal") { s in
            s.bookmarks.removeLast(15)
            s.bookmarks.append(Sample.page("pinned last"))
            s.bookmarks.insert(gone, at: 3)
        }
        let again = FakeMac(cloud, a.library, clock: a.clock + 60, state: try saved(a.session.state))
        again.session.checkAfterLaunch()
        #expect(again.session.state.heldRemovals == 15)
        let urls = again.library.urls(in: "Personal")
        #expect(urls.contains("pinned last"))
        #expect(!urls.contains(gone.url.lastPathComponent))
        again.sync(); b.sync()
        #expect(b.library.urls(in: "Personal").contains("pinned last"))
        #expect(!b.library.urls(in: "Personal").contains(gone.url.lastPathComponent))
    }

    @Test func endingBeforeLibraryJsonIsSavedDoesntRemoveWhatJustArrived() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let onDisk = a.library
        let saved0 = a.clock
        b.edit { $0.editSpace("Personal") { $0.bookmarks.append(contentsOf: [Sample.page("n1"), Sample.page("n2"), Sample.page("n3")]) } }
        b.sync()
        a.clock += 10
        a.sync()
        #expect(a.library.urls(in: "Personal").count == 4)
        // Zigzag ended after State.json was saved, before Library.json was.
        let again = FakeMac(cloud, onDisk, clock: a.clock + 60, state: try saved(a.session.state))
        again.host.libraryStamp = saved0
        again.session.checkAfterLaunch()
        again.sync(); b.sync()
        #expect(b.library.urls(in: "Personal").count == 4)
        #expect(again.library.urls(in: "Personal").count == 4)
    }

    @Test func aMacRestoredFromABackupDoesntBringBackAPinRemovedSince() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        // A backup made while A was offline with an edit not yet sent.
        a.online = false
        a.edit { $0.editSpace("Personal") { $0.bookmarks[1].title = "edited offline" } }
        let backupState = try saved(a.session.state), backupLibrary = a.library
        a.online = true
        a.sync(); b.sync()
        // The page removed by hand a day later.
        a.clock += 86400
        a.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 1) } }
        a.sync(); b.sync()
        #expect(b.library.urls(in: "Personal") == ["a"])
        // The disk died; A comes back from the backup.
        let restored = FakeMac(cloud, backupLibrary, clock: a.clock + 86400, state: backupState)
        restored.session.checkAfterLaunch()
        restored.session.requeue()
        restored.sync(); b.sync()
        #expect(restored.library.urls(in: "Personal") == ["a"])
        #expect(b.library.urls(in: "Personal") == ["a"])
    }

    @Test func aSecondMacWaitsForTheFirstMacsClaimToBeComplete() throws {
        let cloud = FakeCloud()
        let pages = (0..<20).map { "p\($0)" }
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", pages.map { Sample.page($0) })]))
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", pages.map { Sample.page($0) })]))
        // Both find iCloud empty; A's claim is saved first, and B's refused.
        a.fetch(); b.fetch()
        #expect(a.saves == [SyncName.claim] && b.saves == [SyncName.claim])
        a.send(); b.send()
        #expect(a.session.state.merged && !b.session.state.merged)
        // A's library goes up in parts; B reads the first part and waits.
        let first = a.saves.filter { $0.hasPrefix("space.") } + a.saves.filter { $0.hasPrefix("page.") }.prefix(5)
        for name in first { if let up = a.session.upload(name) { cloud.save(up) } }
        b.sync()
        #expect(!b.session.state.merged)
        for _ in 0..<4 { a.sync(); b.sync() }
        #expect(b.session.state.merged)
        #expect(a.library.urls(in: "Personal").count == 20 && b.library.urls(in: "Personal").count == 20)
        #expect(cloud.records.keys.filter { $0.hasPrefix("page.") }.count == 20)
        #expect(cloud.records.keys.filter { $0.hasPrefix("space.") }.count == 1)
    }

    @Test func aFirstMacQuittingHalfwayLosesNothing() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("y")])]))
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("z")])]))
        a.fetch(); b.fetch()
        a.send(); b.send()
        // A sends its space, then quits for a long while.
        for name in a.saves where name.hasPrefix("space.") { if let up = a.session.upload(name) { cloud.save(up) } }
        b.sync()
        #expect(!b.session.state.merged)
        b.clock += SyncSession.claimTimeout + 1
        b.sync()
        #expect(b.session.state.merged)
        for _ in 0..<3 { a.sync(); b.sync() }
        for mac in [a, b] {
            #expect(mac.library.spaceNames == ["Personal"])
            // Nothing lost; x may be there twice, as each Mac's.
            #expect(Set(mac.library.urls(in: "Personal")) == ["x", "y", "z"])
        }
        #expect(a.library.urls(in: "Personal").sorted() == b.library.urls(in: "Personal").sorted())
    }

    @Test func aPinSentDuringTheFullReadAfterTurningOnIsntTakenAsRemoved() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a")])]))
        let off = try saved(ICloudSync.stateTurningOff(b.session.state))
        var library = b.library
        library.editSpace("Personal") { $0.bookmarks.append(Sample.page("pinned while off")) }
        let again = FakeMac(cloud, library, clock: b.clock + 3600, state: ICloudSync.stateTurningOn(saved: off))
        again.session.checkAfterLaunch()
        again.session.requeue()
        // The full read lists the zone in pages; this Mac's pin goes up between them.
        let started = again.clock
        let snapshot = cloud.changes(since: 0)
        again.session.fetched(snapshot.records, deleted: [], startedAt: started)
        again.session.updateState { $0.zoneToken = Data(String(snapshot.token).utf8) }
        again.clock += 1
        again.send()
        again.session.readAll(Set(snapshot.records.map(\.name)), startedAt: started)
        again.session.fetchFinished()
        // Right after the read, not only once a later fetch brought it back.
        #expect(again.library.urls(in: "Personal") == ["a", "pinned while off"])
        again.sync(); a.sync()
        #expect(again.library.urls(in: "Personal") == ["a", "pinned while off"])
        #expect(a.library.urls(in: "Personal") == ["a", "pinned while off"])
    }

    @Test func aLaterJoinerAfterARemovalMergesAtOnce() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", (0..<20).map { Sample.page("p\($0)") })]))
        a.sync()
        a.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 3) } }
        a.sync()
        let c = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("c-only")])]), clock: a.clock + 86400 * 14)
        c.sync()
        #expect(c.session.state.merged)
        #expect(c.library.urls(in: "Personal").count == 20)
        // The claim stays, complete, A's.
        let claim = try #require(cloud.records[SyncName.claim])
        #expect(try SyncBody.decoder().decode(SyncSession.SyncClaim.self, from: claim.payload).complete)
    }

    @Test func aLaterJoinerKeepsItsOwnDuplicatePin() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", (0..<5).map { Sample.page("p\($0)") })]))
        a.sync()
        a.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 3) } }
        a.sync()
        let c = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("p0"), Sample.page("p0"), Sample.page("c-only")])]), clock: a.clock + 86400)
        c.sync()
        #expect(c.session.state.merged)
        c.clock += SyncSession.claimTimeout + 1
        c.sync()
        for _ in 0..<3 { a.sync(); c.sync() }
        #expect(c.library.urls(in: "Personal").filter { $0 == "p0" }.count == 2)
        #expect(a.library.urls(in: "Personal").filter { $0 == "p0" }.count == 2)
    }

    @Test func aLaterJoinerWithoutARemovalKeepsItsDuplicatePin() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", (0..<5).map { Sample.page("p\($0)") })]))
        a.sync()
        let c = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("p0"), Sample.page("p0"), Sample.page("c-only")])]), clock: a.clock + 86400)
        c.sync()
        for _ in 0..<3 { a.sync(); c.sync() }
        #expect(c.session.state.merged && c.library.urls(in: "Personal").filter { $0 == "p0" }.count == 2)
    }

    @Test func aPinMovedSinceTheFirstSyncIsntMatchedWhereItWas() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("news"), Sample.page("gone")]), Sample.space("Work")]))
        a.sync()
        a.edit { lib in
            let news = lib.space(named: "Personal")!.bookmarks[0]
            lib.editSpace("Personal") { $0.bookmarks = [] }
            lib.editSpace("Work") { $0.bookmarks = [news] }
        }
        a.sync()
        let c = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("news")]), Sample.space("Work")]), clock: a.clock + 86400)
        c.sync()
        c.clock += SyncSession.claimTimeout + 1
        c.sync()
        for _ in 0..<3 { a.sync(); c.sync() }
        for mac in [a, c] {
            #expect(mac.library.urls(in: "Work") == ["news"] && mac.library.urls(in: "Personal") == ["news"])
        }
    }

    @Test func aPreferenceChangedWhileOffCountsFromWhenItChanged() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal")], settings: ["ReaderSize": .int(16), "DarkPages": .bool(false)]))
        let libSaved = b.clock
        let off = try saved(ICloudSync.stateTurningOff(b.session.state))
        // A changes both an hour later.
        a.clock = libSaved + 3600
        a.edit { $0.settings["ReaderSize"] = .int(20); $0.settings["DarkPages"] = .bool(true) }
        a.sync()
        // B, off, changed ReaderSize two hours later, and DarkPages half an hour after it was saved; Library.json not saved since.
        var library = b.library
        library.settings["ReaderSize"] = .int(24)
        library.settings["DarkPages"] = .bool(false)
        let again = FakeMac(cloud, library, clock: libSaved + 7200 + 60, state: ICloudSync.stateTurningOn(saved: off))
        again.host.libraryStamp = libSaved
        again.host.settingTimes = ["ReaderSize": libSaved + 7200, "DarkPages": libSaved + 1800]
        again.session.checkAfterLaunch()
        again.sync(); a.sync()
        for mac in [again, a] {
            #expect(mac.library.settings["ReaderSize"] == .int(24))
            #expect(mac.library.settings["DarkPages"] == .bool(true))
        }
        // Without a time noted, it counts from now, never from the library file's date.
        let (cloud2, c, d) = twoMacs(Sample.library([Sample.space("Personal")], settings: ["ReaderSize": .int(16)]))
        let saved2 = d.clock
        let off2 = try saved(ICloudSync.stateTurningOff(d.session.state))
        c.clock = saved2 + 3600
        c.edit { $0.settings["ReaderSize"] = .int(20) }
        c.sync()
        var library2 = d.library
        library2.settings["ReaderSize"] = .int(24)
        let again2 = FakeMac(cloud2, library2, clock: saved2 + 7200, state: ICloudSync.stateTurningOn(saved: off2))
        again2.host.libraryStamp = saved2
        again2.session.checkAfterLaunch()
        again2.sync(); c.sync()
        #expect(c.library.settings["ReaderSize"] == .int(24))
    }

    @Test func anUndoneUnpinSurvivesAHeldLaunch() throws {
        let (cloud, a, _) = manyPages()
        let x = a.library.space(named: "Personal")!.bookmarks[0]
        a.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 0) } }
        a.sync()
        // Undo puts it back (same ID), and an old copy lost 15 others, before sync read it; Library.json saved then.
        a.clock += 1
        a.library.editSpace("Personal") { s in s.bookmarks.insert(x, at: 0); s.bookmarks.removeLast(15) }
        let again = FakeMac(cloud, a.library, clock: a.clock + 60, state: try saved(a.session.state))
        again.host.libraryStamp = a.clock
        again.session.checkAfterLaunch()
        #expect(again.session.state.heldRemovals == 15)
        #expect(again.library.urls(in: "Personal").contains(x.url.lastPathComponent))
        again.sync()
        #expect(cloud.records[SyncName.page(x.id)] != nil)
        // Read as a re-add, it leaves the removed list.
        #expect(again.session.state.removed[SyncName.page(x.id)] == nil)
    }

    @Test func afterASendTheLineSaysLastSyncedWhateverIsHeld() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ICloudSync.status(afterSending: .syncing, merged: true, lastSynced: date) == .synced(date))
        #expect(ICloudSync.status(afterSending: .offline, merged: true, lastSynced: date) == .offline)
        #expect(ICloudSync.status(afterSending: .syncing, merged: false, lastSynced: date) == .syncing)
    }

    @Test func aRestoredMacSendingBeforeAnyFetchDoesntBringBackARemovedPin() throws {
        let (cloud, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        a.online = false
        a.edit { $0.editSpace("Personal") { $0.bookmarks[1].title = "edited offline" } }
        let backupState = try saved(a.session.state), backupLibrary = a.library
        let page = try #require(pageName(a, "b"))
        a.online = true
        a.sync(); b.sync()
        a.clock += 86400
        a.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 1) } }
        a.sync(); b.sync()
        // The restored Mac's engine sends its old edit, twice, before any fetch.
        let restored = FakeMac(cloud, backupLibrary, clock: a.clock + 86400, state: backupState)
        var asked = false
        restored.session.onNeedsFetch = { asked = true }
        restored.session.checkAfterLaunch()
        restored.session.requeue()
        restored.send()
        restored.session.requeue()
        restored.send()
        #expect(asked)
        #expect(cloud.records[page] == nil)
        restored.sync(); b.sync()
        #expect(restored.library.urls(in: "Personal") == ["a"])
        #expect(b.library.urls(in: "Personal") == ["a"])
        #expect(cloud.records[page] == nil)
    }

    @Test func aRemovalFromAMacWhoseClockRunsFastDoesntBeatALaterEdit() throws {
        let (_, a, b) = twoMacs(Sample.library([Sample.space("Personal", [Sample.page("a"), Sample.page("b")])]))
        b.clock = a.clock + 86400
        b.skew = 86400
        b.edit { $0.editSpace("Personal") { $0.bookmarks.remove(at: 1) } }
        a.clock += 60
        a.edit { $0.editSpace("Personal") { $0.bookmarks[1].title = "edited after" } }
        b.sync(); a.sync(); b.sync()
        #expect(a.library.titles(in: "Personal").contains("edited after"))
        #expect(b.library.titles(in: "Personal").contains("edited after"))
    }
}

// MARK: - The claim, stalled or taken over

extension SyncTests {
    private func claim(_ cloud: FakeCloud) -> SyncSession.SyncClaim? {
        cloud.records[SyncName.claim].flatMap { try? SyncBody.decoder().decode(SyncSession.SyncClaim.self, from: $0.payload) }
    }
    private func describe(_ n: String, _ m: FakeMac) -> String {
        "\(n): spaces \(m.library.spaceNames) personal \(m.library.contents.spaces.filter { $0.name == "Personal" }.map { $0.bookmarks.map(\.url.lastPathComponent) }) work \(m.library.contents.directory.all.filter { $0.name == "Work" }.count) favs \(m.library.contents.favorites.count) merged \(m.session.state.merged)"
    }

    /// The first Mac claims, then sleeps over 30 minutes before sending its library; the other takes the claim over.
    @Test func aStalledFirstMacsClaimIsTakenOverWithoutCopies() {
        let cloud = FakeCloud()
        var one = ProfileDirectory(), two = ProfileDirectory()
        _ = one.add(name: "Work"); _ = two.add(name: "Work")
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("y")])], favorites: [Sample.page("mail")], directory: one))
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("z")])], favorites: [Sample.page("mail")], directory: two))
        a.fetch(); b.fetch()
        // Only A's claim goes up; A's library stays queued (lid closed).
        if let up = a.session.upload(SyncName.claim) { if case .saved(let r) = cloud.save(up) { a.session.saved([r]) } }
        b.send()
        b.clock += SyncSession.claimTimeout + 1
        b.sync()
        a.clock = b.clock
        for _ in 0..<4 { a.sync(); b.sync() }
        #expect(a.library.spaceNames == ["Personal"], "\(describe("a", a))")
        #expect(cloud.records.keys.filter { $0.hasPrefix("space.") }.count == 1)
        #expect(b.library.spaceNames == ["Personal"] && Set(a.library.urls(in: "Personal")) == ["x", "y", "z"])
        #expect(a.library.urls(in: "Personal").sorted() == b.library.urls(in: "Personal").sorted())
        #expect(claim(cloud)?.complete == true)
    }

    /// An old incomplete claim (a Mac that claimed and turned off), then two Macs at once.
    @Test func anOldIncompleteClaimStillKeepsTwoAtOnceApart() {
        let cloud = FakeCloud()
        let z = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x")])]))
        z.fetch()
        if let up = z.session.upload(SyncName.claim) { cloud.save(up) }
        let later = z.clock + 3600
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("y")])]), clock: later)
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("y"), Sample.page("z")])]), clock: later)
        a.fetch(); b.fetch()
        a.send(); b.send()
        for _ in 0..<3 { a.sync(); b.sync() }
        #expect(a.library.spaceNames == ["Personal"], "\(describe("a", a))")
    }

    /// The first Mac turned off and on halfway through its first sync.
    @Test func aFirstMacTurnedOffAndOnHalfwayCompletesItsClaim() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", (0..<10).map { Sample.page("p\($0)") })]))
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("p0"), Sample.page("b")])]))
        a.fetch(); b.fetch(); a.send(); b.send()
        #expect(a.session.state.merged && a.session.state.claimed)
        for name in a.saves.filter({ $0.hasPrefix("space.") }) { if let up = a.session.upload(name) { cloud.save(up) } }
        let off = try saved(ICloudSync.stateTurningOff(a.session.state))
        let again = FakeMac(cloud, a.library, clock: a.clock + 60, state: ICloudSync.stateTurningOn(saved: off))
        again.session.checkAfterLaunch(); again.session.requeue()
        for _ in 0..<4 { again.sync() }
        b.clock = again.clock
        b.sync()
        #expect(claim(cloud)?.complete == true)
        #expect(b.session.state.merged)
    }

    /// The claim saved, and Zigzag quit before noting it.
    @Test func aClaimSavedJustBeforeAQuitIsCarriedOn() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", (0..<5).map { Sample.page("p\($0)") })]))
        a.fetch()
        if let up = a.session.upload(SyncName.claim) { cloud.save(up) }
        let state = ICloudSync.stateAtLaunch(saved: try saved(a.session.state), libraryWasRead: true)
        let again = FakeMac(cloud, a.library, clock: a.clock + 10, state: state)
        again.session.requeue()
        for _ in 0..<4 { again.sync() }
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("b")])]), clock: again.clock + 60)
        b.sync()
        #expect(claim(cloud)?.complete == true)
        #expect(b.session.state.merged)
    }

    /// The first Mac's State.json lost halfway through its first sync.
    @Test func aFirstMacThatLostItsStateConverges() throws {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", (0..<5).map { Sample.page("p\($0)") })]))
        a.fetch(); a.send()
        for name in a.saves.filter({ $0.hasPrefix("space.") }) + a.saves.filter({ $0.hasPrefix("page.") }).prefix(2) { if let up = a.session.upload(name) { cloud.save(up) } }
        let again = FakeMac(cloud, a.library, clock: a.clock + 10)
        again.sync()
        let waited = !again.session.state.merged
        again.clock += SyncSession.claimTimeout + 1
        for _ in 0..<3 { again.sync() }
        #expect(again.library.urls(in: "Personal").count == 5)
        #expect(cloud.records.keys.filter { $0.hasPrefix("page.") }.count == 5)
        #expect(claim(cloud)?.complete == true)
    }

    /// Three Macs at once.
    @Test func threeMacsAtOnceMakeNoCopies() {
        let cloud = FakeCloud()
        let macs = ["a", "b", "c"].map { n in FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page(n)])])) }
        for m in macs { m.fetch() }
        for m in macs { m.send() }
        for _ in 0..<3 { for m in macs { m.sync() } }
        for m in macs { m.clock += 60 }
        for _ in 0..<3 { for m in macs { m.sync() } }
        for m in macs { #expect(m.library.urls(in: "Personal").sorted() == ["a", "b", "c", "x"]) }
    }

    /// A waiting Mac whose clock runs 31 minutes ahead, while the first Mac's library is still going up.
    @Test func aWaitingMacWhoseClockRunsAheadStillWaits() {
        let cloud = FakeCloud()
        let a = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("y")])]))
        let b = FakeMac(cloud, Sample.library([Sample.space("Personal", [Sample.page("x"), Sample.page("z")])]), clock: Date(timeIntervalSince1970: 1_800_000_000 + SyncSession.claimTimeout + 60))
        b.skew = SyncSession.claimTimeout + 60
        a.fetch(); b.fetch()
        if let up = a.session.upload(SyncName.claim) { if case .saved(let r) = cloud.save(up) { a.session.saved([r]) } }
        b.send()
        b.sync()
        for _ in 0..<3 { a.sync(); b.sync() }
        #expect(a.library.spaceNames == ["Personal"])
    }
}

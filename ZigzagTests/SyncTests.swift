import AppKit
import Foundation
import Testing
@testable import Zigzag

// MARK: - A stand-in for iCloud, and Macs that sync with it

/// The private database's zone as CloudKit keeps it: each record with a change tag, saves that name a stale tag
/// refused, and a change log each Mac reads from where it left off.
@MainActor final class FakeCloud {
    struct Stored { var type: String; var payload: Data; var modified: Date; var tag: Int }
    private(set) var records: [String: Stored] = [:]
    private var log: [String] = []
    private var tags = 0

    func remote(_ name: String) -> SyncRemote? {
        records[name].map { SyncRemote(name: name, type: $0.type, payload: $0.payload, modified: $0.modified, systemFields: Data(String($0.tag).utf8)) }
    }

    enum Saved { case saved(SyncRemote), failed(SyncSaveFailure) }

    @discardableResult
    func save(_ upload: SyncUpload) -> Saved {
        let tag = upload.systemFields.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
        if let current = records[upload.name] {
            if tag != current.tag, let server = remote(upload.name) { return .failed(.conflict(server)) }
        } else if tag != nil {
            return .failed(.gone)
        }
        tags += 1
        records[upload.name] = Stored(type: upload.type, payload: upload.payload, modified: upload.modified, tag: tags)
        log.append(upload.name)
        return .saved(remote(upload.name)!)
    }

    func delete(_ name: String) {
        records[name] = nil
        log.append(name)
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
@MainActor final class FakeMac: SyncServer {
    let host: MemoryHost
    let session: SyncSession
    let cloud: FakeCloud
    var online = true
    private var token = 0
    private(set) var saves: [String] = []
    private(set) var deletes: [String] = []
    private(set) var sent = 0
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

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

    func fetch() {
        let changes = cloud.changes(since: token)
        token = changes.token
        session.fetched(changes.records, deleted: changes.deleted)
        session.fetchFinished()
    }

    func send() {
        let names = saves, gone = deletes
        saves = []
        deletes = []
        var saved: [SyncRemote] = []
        for name in names {
            guard let upload = session.upload(name) else { continue }
            sent += 1
            switch cloud.save(upload) {
            case .saved(let record): saved.append(record)
            case .failed(let failure): session.saveFailed(name, failure)
            }
        }
        session.saved(saved)
        for name in gone { cloud.delete(name) }
        session.deleted(gone)
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
        #expect(SyncPreferences.owner("PasswordsAutofill.\(work.uuidString)") == (true, work))
        #expect(SyncPreferences.owner("PasswordsManager").carried == false)
    }

    // MARK: Account and settling

    @Test func anotherAccountIsNeverSyncedWithoutAsking() {
        #expect(ICloudSync.mayUse(account: "_abc", saved: nil))
        #expect(ICloudSync.mayUse(account: "_abc", saved: "_abc"))
        #expect(!ICloudSync.mayUse(account: "_xyz", saved: "_abc"))
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
                == String(localized: "Up to date", comment: "Status under Sync with iCloud in Settings › General: everything has synced."))
        #expect(SyncSettingsRows.describe(.synced(now.addingTimeInterval(-120)), hasCopy: true, now: now).text.contains("2"))
        let signedOut = SyncSettingsRows.describe(.notSignedIn, hasCopy: true, now: now)
        #expect(signedOut.action == String(localized: "Open System Settings", comment: "Button beside “Not signed in to iCloud” in Settings › General: opens Apple Account in System Settings."))
        #expect(!SyncSettingsRows.describe(.full, hasCopy: true, now: now).text.isEmpty)
        // Off by default, with nothing under it.
        let settings = SettingsView(pane: .general)
        #expect(!settings.syncRows.toggle.isOn)
        #expect(!settings.syncRows.statusRow.isAvailable)
    }

    @Test func aBackupIsSavedBeforeTheFirstSync() throws {
        let url = try #require(ICloudSync.shared.backUp())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.deletingLastPathComponent().lastPathComponent == "Backups")
        guard case .success(let backup) = ZigzagBackup.read(url) else { Issue.record("the backup doesn't read"); return }
        #expect(backup.spaces.map(\.id) == Library.shared.spaces.map(\.id))
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
            for (name, status, isOn, hasCopy) in SyncSettingsRows.everyStatus {
                settings.syncRows.show(status, isOn: isOn, hasCopy: hasCopy)
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
}

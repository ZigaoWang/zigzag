import Foundation

/// Where sync reads and writes the library: Zigzag's own, or a test's.
protocol SyncHost: AnyObject {
    func read() -> SyncLibrary
    func write(_ library: SyncLibrary)
    /// When the library's file was last written, if it has one.
    var libraryStamp: Date? { get }
    /// When each carried preference last changed while sync wasn't reading them (off), by key.
    var settingTimes: [String: Date] { get }
}

extension SyncHost {
    var libraryStamp: Date? { nil }
    var settingTimes: [String: Date] { [:] }
}

/// The server's side: CKSyncEngine, or a test's stand-in for iCloud.
protocol SyncServer: AnyObject {
    /// Records to send, by name, when the server next sends.
    func queue(saves: [String], deletes: [String])
}

/// Fetching and sending, as CKSyncEngine does: what a fetch brings arrives through the session, and once the first
/// sync has merged, the fetch settles it itself.
protocol SyncTransport: AnyObject {
    func fetchChanges(_ scope: SyncFetchScope) async throws
    func sendChanges() async throws
}

enum SyncFetchScope {
    /// Only what a push said changed.
    case pending
    /// The zone's changes since the last fetch, asked of the server whether or not a push came.
    case zone
}

/// A record as the server has it.
struct SyncRemote: Codable {
    var name: String
    var type: String
    /// Its fields as the server holds them, a newer Zigzag's included.
    var payload: Data
    var modified: Date
    /// The server's own fields (its change tag), handed back with the next save so a stale one is caught.
    var systemFields: Data?
    /// When the server last saved it, so an older copy arriving late is told apart.
    var serverModified: Date? = nil
}

/// A record ready to send.
struct SyncUpload {
    var name: String
    var type: String
    var payload: Data
    var modified: Date
    var systemFields: Data?
}

/// Why the server didn't take a save.
enum SyncSaveFailure {
    /// Another Mac changed it first: here's its version.
    case conflict(SyncRemote)
    /// Another Mac changed it first, without its version: it's fetched, then merged and sent again.
    case conflictUnread
    /// It was removed from the server since.
    case gone
    /// The zone isn't there (removed, or never made).
    case zoneMissing
}

/// A favorite or a preference of a profile removed on another Mac, or a space moved off it, read just before the
/// profile's own removal: kept for that fetch and the next only, so one removed on purpose never comes back later.
struct SyncLeftover: Codable {
    /// The fetch it came in (`SyncState.fetches`).
    var fetch: Int
    var favorite: SyncItem?
    var value: SettingValue?
    /// The profile a space was on, by its iCloud ID.
    var profile: UUID?
}

/// Why the server didn't take a removal.
enum SyncDeleteFailure {
    /// It wasn't there any more.
    case gone
    /// The zone isn't there.
    case zoneMissing
}

/// What sync keeps between launches, beside the server's own state.
struct SyncState: Codable {
    /// The records as this Mac and iCloud last agreed on them, with what this Mac changed since on top.
    var base: [String: SyncItem] = [:]
    /// Each record's fields as the server last had them, a newer Zigzag's included.
    var serverPayloads: [String: Data] = [:]
    var systemFields: [String: Data] = [:]
    /// Records changed here that the server hasn't confirmed.
    var unsent: Set<String> = []
    var aliases = SyncAliases()
    var emptyFolders: Set<UUID> = []
    /// The first sync's merge is done.
    var merged = false
    /// The iCloud account it syncs with (its user record's name).
    var account: String?
    var lastSynced: Date?
    /// CKSyncEngine's own state.
    var engine: Data?
    /// Profiles removed on another Mac: they stay here, with their spaces, favorites and data, as this Mac's own.
    var keptProfiles: Set<UUID> = []
    /// What a fetch brought that isn't in the library yet, saved with the server's token so a quit can't lose it.
    var incoming: [String: SyncRemote] = [:]
    var incomingRemoved: Set<String> = []
    /// When the server last saved each record, as this Mac last had it.
    var serverDates: [String: Date] = [:]
    /// When the fetch that brought each record's newest save started, so a removal from a fetch that started before
    /// it (two fetches crossing) is told apart.
    var savedSeen: [String: Date] = [:]
    /// Favorites (by record name) and preferences (by key) of another profile removed elsewhere lately: when the
    /// profile's own removal follows, they come back with it.
    var leftovers: [String: SyncLeftover] = [:]
    /// Fetches settled so far.
    var fetches = 0
    /// Records removed, here or elsewhere, and when this Mac learned it: an old copy's pin is told from a new one.
    var removed: [String: Date] = [:]
    /// Removals found at launch, many at once, that wait to be confirmed or brought back: not shown, not sent.
    var heldNames: Set<String> = []
    var heldRemovals: Int? { heldNames.isEmpty ? nil : heldNames.count }
    /// Library.json's own date when sync last read it, so one put back from an older copy is told apart.
    var libraryStamp: Date?
    /// When sync last wrote into the library.
    var wroteLibrary: Date?
    /// While off: the account the kept state was synced with.
    var resumeAccount: String?
    /// Turned on again with what was kept while off, until the first catch-up.
    var resumed = false
    /// The record this Mac's first sync into an empty iCloud left (`SyncSession.firstSyncType`).
    var ownFirstSync: String?
    /// Saves that found their record gone, waiting for a fetch of iCloud's removals before they're decided.
    var goneAsked: Set<String> = []
    var goneRead: Set<String> = []
    /// Since when the first sync has waited for another Mac's still going up.
    var firstSyncWait: Date?
    /// Copies dropped here (two first syncs at once), not taken again if read before their removal is.
    var copies: Set<String> = []
    /// How far Zigzag's own fetch of the zone has read, beside CKSyncEngine's.
    var zoneToken: Data?

    private enum CodingKeys: String, CodingKey {
        case base, serverPayloads, systemFields, unsent, aliases, emptyFolders, merged, account, lastSynced, engine, keptProfiles
        case incoming, incomingRemoved, serverDates, zoneToken, leftovers, removed, heldNames, libraryStamp, wroteLibrary, resumeAccount, resumed, ownFirstSync, firstSyncWait, goneAsked, copies, savedSeen, fetches
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent([String: SyncItem].self, forKey: .base) ?? [:]
        serverPayloads = try c.decodeIfPresent([String: Data].self, forKey: .serverPayloads) ?? [:]
        systemFields = try c.decodeIfPresent([String: Data].self, forKey: .systemFields) ?? [:]
        unsent = try c.decodeIfPresent(Set<String>.self, forKey: .unsent) ?? []
        aliases = try c.decodeIfPresent(SyncAliases.self, forKey: .aliases) ?? SyncAliases()
        emptyFolders = try c.decodeIfPresent(Set<UUID>.self, forKey: .emptyFolders) ?? []
        merged = try c.decodeIfPresent(Bool.self, forKey: .merged) ?? false
        account = try c.decodeIfPresent(String.self, forKey: .account)
        lastSynced = try c.decodeIfPresent(Date.self, forKey: .lastSynced)
        engine = try c.decodeIfPresent(Data.self, forKey: .engine)
        keptProfiles = try c.decodeIfPresent(Set<UUID>.self, forKey: .keptProfiles) ?? []
        incoming = try c.decodeIfPresent([String: SyncRemote].self, forKey: .incoming) ?? [:]
        incomingRemoved = try c.decodeIfPresent(Set<String>.self, forKey: .incomingRemoved) ?? []
        serverDates = try c.decodeIfPresent([String: Date].self, forKey: .serverDates) ?? [:]
        zoneToken = try c.decodeIfPresent(Data.self, forKey: .zoneToken)
        leftovers = try c.decodeIfPresent([String: SyncLeftover].self, forKey: .leftovers) ?? [:]
        heldNames = try c.decodeIfPresent(Set<String>.self, forKey: .heldNames) ?? []
        removed = try c.decodeIfPresent([String: Date].self, forKey: .removed) ?? [:]
        libraryStamp = try c.decodeIfPresent(Date.self, forKey: .libraryStamp)
        wroteLibrary = try c.decodeIfPresent(Date.self, forKey: .wroteLibrary)
        resumeAccount = try c.decodeIfPresent(String.self, forKey: .resumeAccount)
        resumed = try c.decodeIfPresent(Bool.self, forKey: .resumed) ?? false
        ownFirstSync = try c.decodeIfPresent(String.self, forKey: .ownFirstSync)
        firstSyncWait = try c.decodeIfPresent(Date.self, forKey: .firstSyncWait)
        goneAsked = try c.decodeIfPresent(Set<String>.self, forKey: .goneAsked) ?? []
        copies = try c.decodeIfPresent(Set<String>.self, forKey: .copies) ?? []
        savedSeen = try c.decodeIfPresent([String: Date].self, forKey: .savedSeen) ?? [:]
        fetches = try c.decodeIfPresent(Int.self, forKey: .fetches) ?? 0
        leftovers = leftovers.filter { $0.value.fetch >= fetches - 1 }
    }
}

/// The sync itself, apart from CloudKit: what changed here goes up, what changed elsewhere comes down, and the two
/// meet without losing either. Last writer wins per record, by its date; preferences per key.
final class SyncSession {
    private(set) var state: SyncState
    let host: SyncHost
    weak var server: SyncServer?
    var now: () -> Date = Date.init
    /// Called whenever `state` changed and should be saved.
    var onChange: (() -> Void)?
    /// Called when removals are held, or no longer are.
    var onHeld: (() -> Void)?
    /// Called when a Library.json older than what was last synced was laid out from iCloud again, and that changed it.
    var onTookICloud: (() -> Void)?
    /// Called when a save finds the zone gone after the first sync: removed from iCloud on another Mac.
    var onRemovedElsewhere: (() -> Void)?
    /// Called when the server's version of something is needed before it can be sent again.
    var onNeedsFetch: (() -> Void)?
    /// True while it writes into the library, so the change that causes isn't read as one made here.
    private(set) var isApplying = false
    /// Sync turned off or started again: a fetch still on its way changes nothing.
    private(set) var isClosed = false

    func close() {
        isClosed = true
        server = nil
    }

    /// What the server sent since the last settle: a record, or nil for one removed.
    private var incoming: [String: SyncRemote?] {
        var all: [String: SyncRemote?] = state.incoming.mapValues { .some($0) }
        for name in state.incomingRemoved { all[name] = .some(nil) }
        return all
    }

    private func arrive(_ name: String, _ record: SyncRemote?) {
        if let record {
            state.incoming[name] = record
            state.incomingRemoved.remove(name)
        } else {
            state.incoming[name] = nil
            state.incomingRemoved.insert(name)
        }
    }

    private func clearIncoming() {
        state.incoming = [:]
        state.incomingRemoved = []
    }

    init(host: SyncHost, state: SyncState = SyncState()) {
        self.host = host
        self.state = state
    }

    func updateState(_ change: (inout SyncState) -> Void) {
        change(&state)
        onChange?()
    }

    // MARK: Changes here

    /// Reads the library and queues what changed since. What's changed here by hand is always sent: only the first
    /// look after launch (`checkAfterLaunch`) can tell a library put back from a copy.
    /// `stamp`: when what changed was changed, if not now.
    func localChanged(stamp: Date? = nil) {
        guard !isClosed, state.merged, !isApplying else { return }
        let library = host.read()
        let export = SyncMapping.export(library, previous: state.base, aliases: state.aliases, emptyBefore: state.emptyFolders,
                                        kept: state.keptProfiles, unsent: state.unsent, now: stamp ?? now(),
                                        settingsChanged: host.settingTimes, settingsNow: now())
        state.emptyFolders = export.emptyFolders
        queue(diff(export.items, deletes: true, stamp: stamp))
        // The file's own date as it is now; one ahead of the clock (a clock set wrong) is no guide.
        if let stamp = host.libraryStamp, stamp <= now().addingTimeInterval(60) { state.libraryStamp = stamp }
        onChange?()
        if export.needsLayout { layOut() }
    }

    /// At launch and when sync is turned on, before anything here is sent: a Library.json older than the one last
    /// synced (put back from Time Machine or a copy) takes iCloud's version of everything, and nothing is sent. Many
    /// things gone at once are held: everything else takes iCloud's version, and the removals wait to be confirmed
    /// (Remove Everywhere) or brought back (Restore). Edits made after it go up as usual.
    func checkAfterLaunch() {
        guard !isClosed, state.merged, !isApplying else { return }
        // What changed since the last sync was changed when Library.json was last saved, never later than now.
        let changedAt = host.libraryStamp.map { min($0, now()) }
        // Older than the file sync last read, or than sync's last write into it (Zigzag ended before saving it).
        func older(than date: Date?) -> Bool {
            guard let date, date <= now().addingTimeInterval(60), let stamp = host.libraryStamp else { return false }
            return stamp < date.addingTimeInterval(-1)
        }
        if older(than: state.libraryStamp) || older(than: state.wroteLibrary) {
            if takeICloudKeepingNew(stamp: changedAt) { onTookICloud?() }
            return
        }
        let export = SyncMapping.export(host.read(), previous: state.base, aliases: state.aliases, emptyBefore: state.emptyFolders,
                                        kept: state.keptProfiles, unsent: state.unsent, now: changedAt ?? now(),
                                        settingsChanged: host.settingTimes, settingsNow: now())
        if let gone = Self.manyRemovals(from: state.base, to: export.items, unsent: state.unsent) {
            state.heldNames.formUnion(gone)
            // Turned on after tidying up while off, the rest is this Mac's own: sent. At a launch, it may be an old
            // copy's: iCloud's version, but what's new here stays.
            if state.resumed { localChanged(stamp: changedAt) } else { takeICloudKeepingNew(stamp: changedAt) }
            onHeld?()
            return
        }
        localChanged(stamp: changedAt)
    }

    /// iCloud's version of everything this Mac and iCloud both have, laid out here; what's only here is sent, unless
    /// it's something removed since (an old copy's), which goes.
    /// Returns whether that changed anything here.
    @discardableResult
    private func takeICloudKeepingNew(stamp: Date?) -> Bool {
        let export = SyncMapping.export(host.read(), previous: state.base, aliases: state.aliases, emptyBefore: state.emptyFolders,
                                        kept: state.keptProfiles, unsent: state.unsent, now: stamp ?? now(),
                                        settingsChanged: host.settingTimes, settingsNow: now())
        // Removed since, unless Library.json was saved after the removal (an unpin undone), so it's back on purpose.
        let saved = host.libraryStamp
        let new = export.items.filter { name, _ in
            guard state.base[name] == nil, SyncName.id(name) != nil else { return false }
            guard let removed = state.removed[name] else { return true }
            return saved.map { $0 > removed } ?? false
        }
        let shown = state.base.filter { !state.heldNames.contains($0.key) && SyncName.id($0.key) != nil && !$0.key.hasPrefix(Self.firstSyncPrefix) }
        let differs = export.items.contains { name, item in new[name] == nil && SyncName.id(name) != nil && shown[name].map { !$0.sameContent(as: item) } ?? true }
            || shown.keys.contains { export.items[$0] == nil }
        queue(diff(new, deletes: false, stamp: stamp))
        layOut()
        return differs
    }

    /// More than 10 of one kind, and more than a quarter of them, gone at once: a library file replaced or rolled
    /// back rather than things removed by hand. Returns everything gone.
    static func manyRemovals(from base: [String: SyncItem], to items: [String: SyncItem], unsent: Set<String> = []) -> Set<String>? {
        var total: [Substring: Int] = [:], gone: [Substring: Int] = [:]
        var names: Set<String> = []
        for (name, item) in base where SyncName.id(name) != nil {
            if case .unknown = item.body { continue }
            let kind = name.prefix { $0 != "." }
            total[kind, default: 0] += 1
            if items[name] == nil, !unsent.contains(name) { gone[kind, default: 0] += 1; names.insert(name) }
        }
        let many = gone.filter { kind, count in count > 10 && Double(count) > Double(total[kind] ?? 0) * 0.25 }
        return many.isEmpty ? nil : names
    }

    /// Held removals brought back, as iCloud has them.
    func bringBackHeld() {
        guard !isClosed, !state.heldNames.isEmpty else { return }
        state.heldNames = []
        layOut()
        onHeld?()
    }

    /// Held removals sent: removed from iCloud, and so from every Mac.
    func sendHeld() {
        guard !isClosed, !state.heldNames.isEmpty else { return }
        let names = state.heldNames.filter { state.base[$0] != nil }
        state.heldNames = []
        for name in names {
            state.base[name] = nil
            state.unsent.remove(name)
            state.removed[name] = now()
        }
        let noted = noteRemovals(Array(names), at: now())
        queue((noted.map { [$0] } ?? [], Array(names)))
        layOut()
        onHeld?()
    }

    /// Everything the server hasn't confirmed, from the state rather than the server's own queue: edits made while
    /// there was no server (offline, before connecting) and what a quit before the server saved its queue lost.
    func requeue() {
        guard !isClosed else { return }
        let deletes = state.serverPayloads.keys.filter { state.base[$0] == nil }
        queue((Array(state.unsent.subtracting(state.goneAsked)), deletes))
    }

    private func queue(_ changes: (saves: [String], deletes: [String])) {
        guard !changes.saves.isEmpty || !changes.deletes.isEmpty else { return }
        server?.queue(saves: SyncName.ordered(changes.saves), deletes: SyncName.ordered(changes.deletes))
    }

    private func diff(_ exported: [String: SyncItem], deletes allowDeletes: Bool, stamp: Date? = nil) -> (saves: [String], deletes: [String]) {
        var items = exported
        var saves: [String] = [], deletes: [String] = []
        let stamp = stamp ?? now()
        // The removals record isn't the library's: kept as it is, and added to below.
        if let removals = state.base[SyncName.removals] { items[SyncName.removals] = removals }
        for (name, var item) in items {
            if let old = state.base[name], old.sameContent(as: item) { continue }
            if item.type != SyncBody.settingsType { item.modified = stamp }
            // Back here (an unpin undone): no longer removed.
            state.removed[name] = nil
            state.base[name] = item
            state.unsent.insert(name)
            saves.append(name)
        }
        if allowDeletes {
            for (name, item) in state.base where items[name] == nil && !state.heldNames.contains(name) {
                // A kind only a newer Zigzag reads is left as it is.
                if case .unknown = item.body { continue }
                state.base[name] = nil
                state.unsent.remove(name)
                deletes.append(name)
                state.removed[name] = stamp
            }
            if !deletes.isEmpty, let name = noteRemovals(deletes, at: stamp) { saves.append(name) }
        }
        return (saves, deletes)
    }

    /// Removals sent from here go in the removals record too, with when. Returns its name when it changed.
    private func noteRemovals(_ names: [String], at date: Date) -> String? {
        var removals: [String: Date] = if case .removals(let r)? = state.base[SyncName.removals]?.body { r.names } else { [:] }
        for name in names where SyncName.id(name) != nil { removals[name] = max(removals[name] ?? date, date) }
        removals = removals.filter { now().timeIntervalSince($0.value) < SyncRemovals.kept }
        state.base[SyncName.removals] = SyncItem(.removals(SyncRemovals(names: removals)), modified: now())
        state.unsent.insert(SyncName.removals)
        return SyncName.removals
    }

    /// When `name` was removed on some Mac, as the removals record has it.
    private func removedAt(_ name: String) -> Date? {
        // One dated ahead of this Mac's clock came from a Mac whose clock runs fast: no guide.
        if case .removals(let r)? = state.base[SyncName.removals]?.body, let at = r.names[name], at <= now().addingTimeInterval(60) { return at }
        return nil
    }

    /// Into the library, noting when, so a Library.json that didn't get it (Zigzag ended before saving) is told apart.
    private func write(_ library: SyncLibrary) {
        isApplying = true
        host.write(library)
        isApplying = false
        state.wroteLibrary = now()
    }

    /// The library laid out from the records, then read back: what that changed (a page whose folder is gone, now
    /// at the top of its space) goes up too.
    private func layOut() {
        write(SyncMapping.apply(state.base.filter { !state.heldNames.contains($0.key) }, onto: host.read(), aliases: state.aliases,
                                kept: state.keptProfiles, unsent: state.unsent).library)
        localChanged()
    }

    // MARK: Changes from the server

    /// `startedAt`: when the fetch that brought these started.
    func fetched(_ records: [SyncRemote], deleted: [String], startedAt: Date? = nil) {
        guard !isClosed else { return }
        let started = startedAt ?? now()
        for record in records {
            // Only a save newer than the one known here: this Mac's own, read back, isn't one.
            let newer = record.serverModified.map { date in state.serverDates[record.name].map { date > $0 } ?? true } ?? true
            if newer { state.savedSeen[record.name] = max(state.savedSeen[record.name] ?? .distantPast, started) }
            arrive(record.name, record)
        }
        // A removal from a fetch that started before one that brought a newer save is stale.
        for name in deleted where !(state.savedSeen[name].map { $0 > started } ?? false) { arrive(name, nil) }
        if !records.isEmpty || !deleted.isEmpty { onChange?() }
    }

    /// A read of the whole zone is done: what iCloud had and doesn't any more was removed there.
    func readAll(_ names: Set<String>) {
        guard !isClosed, state.merged else { return }
        for name in state.serverPayloads.keys where !names.contains(name) && state.incoming[name] == nil { arrive(name, nil) }
    }

    /// A fetch is done: the first sync merges, later ones settle what came.
    func fetchFinished() {
        guard !isClosed else { return }
        if !state.merged {
            // Another Mac's first sync still going up: read again before merging, for a while. iCloud with a library
            // and no first sync going up: merged at once, the usual way.
            if halfSentFirstSync() {
                let since = state.firstSyncWait ?? now()
                state.firstSyncWait = since
                if now().timeIntervalSince(since) < Self.firstSyncWait {
                    onChange?()
                    onNeedsFetch?()
                    return
                }
                mergeFirst(leavingRecord: true)
            } else {
                mergeFirst()
            }
        } else {
            settle()
            removeOwnFirstSync()
            // Saves that found their record gone, now that iCloud's removals are read.
            for name in state.goneAsked where state.unsent.contains(name) {
                state.goneRead.insert(name)
                decideGone(name)
            }
            state.goneAsked = []
        }
        state.lastSynced = now()
        onChange?()
    }

    private func settle() {
        guard !state.incoming.isEmpty || !state.incomingRemoved.isEmpty else { return }
        // What changed here first, so it isn't taken for something the server undid.
        localChanged()
        var arrived = incoming
        clearIncoming()
        for name in state.copies where arrived[name] != nil {
            // A copy dropped here, read again before its removal.
            if case .some(.none) = arrived[name] { state.copies.remove(name) }
            arrived[name] = nil
        }
        var changed = false
        var resend: [String] = []
        var profilesGone: Set<UUID> = []
        // Copies from two first syncs at once that the other Mac already removed: not kept as removed elsewhere.
        var markers = state.base.filter { $0.value.type == Self.firstSyncType }
        var markerDates = state.serverDates
        for case let (name, record?) in arrived where record.type == Self.firstSyncType {
            markers[name] = SyncItem(type: record.type, payload: record.payload, modified: record.modified)
            markerDates[name] = record.serverModified ?? markerDates[name]
        }
        let copyPairs = Self.copies(in: markers, dates: markerDates, now: now(), asSent: true)
        var copiesGone: [UUID] = []
        let stamp = now()
        state.fetches += 1
        let fetch = state.fetches
        state.leftovers = state.leftovers.filter { $0.value.fetch >= fetch - 1 }
        state.savedSeen = state.savedSeen.filter { stamp.timeIntervalSince($0.value) < 24 * 3600 }
        state.removed = state.removed.filter { stamp.timeIntervalSince($0.value) < 180 * 24 * 3600 }
        // Records first, then copies dropped, then removals, so a copy's removal is read as one.
        for case let (name, record?) in arrived {
            // A space moved off another profile to the first one: that profile's removal may be next.
            if case .space(let old)? = state.base[name]?.body, old.profile != Profile.defaultID,
               case .space(let new) = SyncBody.decode(type: record.type, payload: record.payload), new.profile == Profile.defaultID {
                state.leftovers["space:" + name] = SyncLeftover(fetch: fetch, profile: old.profile)
            }
            let outcome = take(record)
            changed = changed || outcome.changed
            if outcome.resend { resend.append(name) }
        }
        if !copyPairs.isEmpty {
            let count = state.base.count
            dropCopies()
            changed = changed || state.base.count != count
        }
        for (name, record) in arrived where record == nil {
            state.systemFields[name] = nil
            state.serverPayloads[name] = nil
            state.serverDates[name] = nil
            // Changed here since: it comes back rather than vanish, unless the removal came after the change (an
            // edit from a Mac restored from a backup).
            if state.unsent.contains(name) {
                if let at = removedAt(name), let edit = state.base[name]?.modified, at > edit {
                    state.unsent.remove(name)
                } else {
                    resend.append(name)
                    continue
                }
            }
            state.heldNames.remove(name)
            if state.base[name] != nil { state.removed[name] = stamp }
            if let item = state.base.removeValue(forKey: name) {
                // A profile removed elsewhere stays here, never its data erased: it's this Mac's own from now on.
                if name.hasPrefix("profile."), let id = SyncName.id(name).map(state.aliases.local), id != Profile.defaultID {
                    if copyPairs[name] != nil {
                        // Unless it's this Mac's own copy, which goes on as the kept one.
                        if state.aliases.server(id) == SyncName.id(name) { copiesGone.append(id) }
                    } else {
                        state.keptProfiles.insert(id)
                        profilesGone.insert(id)
                    }
                }
                // Another profile's favorite: kept a while, in case its profile's removal comes next.
                if case .favorite(let favorite) = item.body, favorite.profile != Profile.defaultID,
                   copyPairs[SyncName.profile(favorite.profile)] == nil {
                    state.leftovers[name] = SyncLeftover(fetch: fetch, favorite: item)
                }
                changed = true
            }
        }
        queue((resend, []))
        guard changed else { return }
        let before = host.read().settings
        layOut()
        // Another profile's preferences unset from elsewhere: kept a while too.
        let after = host.read().settings
        for (key, value) in before where after[key] == nil {
            if let profile = SyncPreferences.owner(key).profile, profile != Profile.defaultID {
                state.leftovers["setting:" + key] = SyncLeftover(fetch: fetch, value: value)
            }
        }
        if !profilesGone.isEmpty { bringBack(profilesGone) }
        if !copiesGone.isEmpty {
            var library = host.read()
            for id in copiesGone { _ = library.contents.directory.remove(id) }
            write(library)
        }
    }

    /// A profile removed elsewhere stays here with what was removed from it just before.
    private func bringBack(_ profiles: Set<UUID>) {
        var library = host.read()
        var directory = library.contents.directory
        var brought = false
        for (name, leftover) in state.leftovers {
            if case .favorite(let favorite)? = leftover.favorite?.body, profiles.contains(state.aliases.local(favorite.profile)),
               let id = SyncName.id(name).map(state.aliases.local), !library.contents.favorites.contains(where: { $0.id == id }) {
                library.contents.favorites.append(Bookmark(id: id, url: favorite.url, title: favorite.title, icon: favorite.icon))
                directory.assign(favorite: id, to: state.aliases.local(favorite.profile))
            } else if name.hasPrefix("space:"), let profile = leftover.profile.map(state.aliases.local), profiles.contains(profile),
                      let id = SyncName.id(String(name.dropFirst("space:".count))).map(state.aliases.local),
                      library.contents.spaces.contains(where: { $0.id == id }) {
                directory.assign(space: id, to: profile)
            } else if name.hasPrefix("setting:"), let value = leftover.value {
                let key = String(name.dropFirst("setting:".count))
                guard let profile = SyncPreferences.owner(key).profile, profiles.contains(profile), library.settings[key] == nil else { continue }
                library.settings[key] = value
            } else {
                continue
            }
            state.leftovers[name] = nil
            brought = true
        }
        guard brought else { return }
        library.contents.directory = directory
        write(library)
    }

    /// The server's version of a record meets this Mac's. Returns whether the library changes, and whether this
    /// Mac's version still has to go up.
    private func take(_ record: SyncRemote) -> (changed: Bool, resend: Bool) {
        // An older copy than the one here (two fetches crossing): nothing to do.
        if let date = record.serverModified, let known = state.serverDates[record.name], date < known { return (false, false) }
        if let date = record.serverModified { state.serverDates[record.name] = date }
        // What both Macs started from, for merging the rules and splits entry by entry.
        let ancestor = state.serverPayloads[record.name].map { SyncItem(type: record.type, payload: $0, modified: .distantPast) }
        state.systemFields[record.name] = record.systemFields
        state.serverPayloads[record.name] = record.payload
        let theirs = SyncItem(SyncBody.decode(type: record.type, payload: record.payload), modified: record.modified)
        guard let mine = state.base[record.name] else {
            state.base[record.name] = theirs
            return (true, false)
        }
        guard state.unsent.contains(record.name) else {
            state.base[record.name] = theirs
            return (!mine.sameContent(as: theirs), false)
        }
        let resolved = Self.resolve(mine, theirs, ancestor: ancestor)
        if resolved.sameContent(as: theirs) {
            state.base[record.name] = theirs
            state.unsent.remove(record.name)
            return (!mine.sameContent(as: theirs), false)
        }
        state.base[record.name] = resolved
        return (!mine.sameContent(as: resolved), true)
    }

    /// Last writer wins, by date; a tie goes to the server's. Preferences meet key by key.
    /// The site rules meet rule by rule, and a space's or profile's splits split by split, against what both started
    /// from (`ancestor`), so an edit on each Mac keeps both.
    static func resolve(_ mine: SyncItem, _ theirs: SyncItem, ancestor: SyncItem? = nil) -> SyncItem {
        let modified = max(mine.modified, theirs.modified)
        let mineWins = mine.modified > theirs.modified
        switch (mine.body, theirs.body, ancestor?.body) {
        case (.settings(let a), .settings(let b), _):
            return SyncItem(.settings(SyncSettings(values: SyncSettings.merged(b.values, a.values))), modified: modified)
        case (.removals(let a), .removals(let b), _):
            return SyncItem(.removals(SyncRemovals(names: a.names.merging(b.names) { max($0, $1) })), modified: modified)
        case (.rules(let m), .rules(let t), let base):
            let a: [SiteRoutes.Route] = if case .rules(let r)? = base { r.routes.rules } else { [] }
            var routes = t.routes
            routes.rules = merged(a, m.routes.rules, t.routes.rules, id: { $0.id.uuidString }, mineWins: mineWins)
            var rules = t
            rules.routes = routes
            return SyncItem(.rules(rules), modified: modified)
        case (.space(let m), .space(let t), let base):
            var winner = mineWins ? m : t
            let a: [PinnedSplit] = if case .space(let s)? = base { s.splits } else { [] }
            winner.splits = merged(a, m.splits, t.splits, id: splitKey, mineWins: mineWins)
            return SyncItem(.space(winner), modified: modified)
        case (.profile(let m), .profile(let t), let base):
            var winner = mineWins ? m : t
            let a: [PinnedSplit] = if case .profile(let p)? = base { p.favoriteSplits } else { [] }
            winner.favoriteSplits = merged(a, m.favoriteSplits, t.favoriteSplits, id: splitKey, mineWins: mineWins)
            return SyncItem(.profile(winner), modified: modified)
        default:
            return mineWins ? mine : theirs
        }
    }

    private static func splitKey(_ split: PinnedSplit) -> String { split.ids.map(\.uuidString).joined(separator: " ") }

    /// A three-way merge of lists by `id`: what only one side changed takes that side's, what both changed the later
    /// side's; theirs keep their order, and what only mine has goes after what it follows in mine.
    static func merged<T: Encodable>(_ ancestor: [T], _ mine: [T], _ theirs: [T], id: (T) -> String, mineWins: Bool) -> [T] {
        func index(_ list: [T]) -> [String: T] { Dictionary(list.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a }) }
        let a = index(ancestor), m = index(mine), t = index(theirs)
        let encoder = SyncBody.encoder()
        func same(_ x: T?, _ y: T?) -> Bool {
            switch (x, y) {
            case (nil, nil): true
            case let (x?, y?): (try? encoder.encode(x)) == (try? encoder.encode(y))
            default: false
            }
        }
        func chosen(_ key: String) -> T? {
            if same(m[key], a[key]) { return t[key] }
            if same(t[key], a[key]) { return m[key] }
            return mineWins ? m[key] : t[key]
        }
        var result = theirs.compactMap { chosen(id($0)) }
        var placed = Set(result.map(id))
        var after: String?
        for item in mine {
            let key = id(item)
            if placed.contains(key) { after = key; continue }
            guard let value = chosen(key) else { continue }
            let at = after.flatMap { k in result.firstIndex { id($0) == k } }.map { $0 + 1 } ?? 0
            result.insert(value, at: at)
            placed.insert(key)
            after = key
        }
        return result
    }

    /// The first sync on this Mac: iCloud's records and the library here merged, never replaced.
    /// This Mac's first-sync record, a day after iCloud saved it with nothing left to send: removed, so it doesn't stay.
    private func removeOwnFirstSync() {
        guard let own = state.ownFirstSync, state.base[own] != nil, state.unsent.isEmpty,
              let saved = state.serverDates[own], now().timeIntervalSince(saved) > Self.firstSyncKept else { return }
        state.base[own] = nil
        state.ownFirstSync = nil
        queue(([], [own]))
    }

    static let firstSyncKept: TimeInterval = 24 * 3600

    /// How long a first sync waits for another Mac's that's still going up.
    static let firstSyncWait: TimeInterval = 10 * 60

    /// A first-sync record iCloud saved lately (or since this Mac began waiting) whose items haven't all arrived yet.
    /// An older one is no first sync still going up: what it lists that's missing was removed since.
    private func halfSentFirstSync() -> Bool {
        let since = (state.firstSyncWait ?? now()).addingTimeInterval(-Self.firstSyncWait)
        let records = state.incoming.filter { $0.value.type == Self.firstSyncType && ($0.value.serverModified ?? now()) >= since }
        return records.values.contains { record in
            guard let sync = try? SyncBody.decoder().decode(FirstSync.self, from: record.payload) else { return false }
            return sync.items.contains { state.incoming[$0.n] == nil && !state.incomingRemoved.contains($0.n) }
        }
    }

    /// `leavingRecord`: another Mac's first sync didn't finish going up in time, so this one leaves its own record
    /// too, and the two are matched as two first syncs at once.
    private func mergeFirst(leavingRecord: Bool = false) {
        state.firstSyncWait = nil
        var server: [String: SyncItem] = [:]
        for case let (name, record?) in incoming {
            if let date = record.serverModified { state.serverDates[name] = date }
            state.systemFields[name] = record.systemFields
            state.serverPayloads[name] = record.payload
            server[name] = SyncItem(SyncBody.decode(type: record.type, payload: record.payload), modified: record.modified)
        }
        clearIncoming()
        let merge = SyncMerge.merge(local: host.read(), server: server, previous: state.aliases, now: now())
        let alone = leavingRecord || !server.keys.contains { SyncName.id($0) != nil }
        state.aliases = merge.aliases
        state.base = server
        state.merged = true
        write(SyncMapping.apply(merge.items, onto: host.read(), aliases: state.aliases).library)
        let export = SyncMapping.export(host.read(), previous: state.base, aliases: state.aliases, now: now())
        state.emptyFolders = export.emptyFolders
        // Nothing in iCloud is removed because this Mac lacks it.
        let changes = diff(export.items, deletes: false)
        if alone {
            // Its record goes up first, so another Mac reading part of this send knows to wait for the rest.
            let name = Self.firstSyncPrefix + UUID().uuidString
            state.base[name] = Self.firstSync(of: state.base.filter { server[$0.key] == nil })
            state.unsent.insert(name)
            state.ownFirstSync = name
            queue(([name], []))
        }
        queue(changes)
    }

    // MARK: Two first syncs at once

    /// A first sync that found iCloud empty leaves a record of what it sent ("FirstSync"): each item with what it's
    /// matched by (its kind, its space, folder or profile, and its name or address). With two or more of them, two
    /// Macs turned on at the same moment and each sent copies of the same things. Every Mac pairs them the same way,
    /// from those records alone: one to one, in ID order, the lower ID kept. Each Mac then drops the other copy and
    /// moves what was in it on its own, so they agree whenever and however each reads, without waiting for the other.
    static let firstSyncType = "FirstSync"
    static let firstSyncPrefix = "firstsync."

    private struct FirstSyncItem: Codable {
        var n: String
        var p: [String]
        var k: String
    }

    private struct FirstSync: Codable {
        var items: [FirstSyncItem]
    }

    /// What an item is matched by: its kind, its space, folder or profile, and its name or address.
    private static func matchItem(_ name: String, _ body: SyncBody) -> FirstSyncItem? {
        func text(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        switch body {
        case .profile(let p) where SyncName.id(name) != Profile.defaultID && !text(p.name ?? "").isEmpty:
            return .init(n: name, p: [], k: text(p.name ?? ""))
        case .space(let s):
            return .init(n: name, p: [SyncName.profile(s.profile)], k: text(s.look.name))
        case .folder(let f):
            return .init(n: name, p: [SyncName.space(f.space), f.parent.map(SyncName.folder) ?? ""], k: "\(text(f.name)) \(f.live == nil)")
        case .page(let p):
            return .init(n: name, p: [SyncName.space(p.space), p.parent.map(SyncName.folder) ?? ""], k: TabManager.pinnedKey(p.url))
        case .favorite(let f):
            return .init(n: name, p: [SyncName.profile(f.profile)], k: TabManager.pinnedKey(f.url))
        default:
            return nil
        }
    }

    /// The record of a first sync into an empty iCloud: what's in `items`, as it was sent.
    private static func firstSync(of items: [String: SyncItem]) -> SyncItem {
        // iCloud takes a record up to 1 MB: past that, the rest isn't matched.
        let list = Array(items.compactMap { matchItem($0.key, $0.value.body) }.sorted { $0.n < $1.n }.prefix(15_000))
        let payload = (try? SyncBody.encoder().encode(FirstSync(items: list))) ?? Data("{}".utf8)
        return SyncItem(type: firstSyncType, payload: payload, modified: Date())
    }

    /// Two first-sync records whose server dates are this close were two first syncs at once.
    static let firstSyncsAtOnce: TimeInterval = 2 * firstSyncWait

    /// Each copy that isn't kept, to the one kept, from first-sync records saved close together (`dates`: when iCloud
    /// saved each; one not yet saved counts as `now`): the same on every Mac. Items are matched as they are now in
    /// `records`; one that's gone isn't matched, unless `asSent` (to tell a copy's removal from another).
    static func copies(in records: [String: SyncItem], dates: [String: Date] = [:], now: Date = Date(), asSent: Bool = false) -> [String: String] {
        let syncs = records.filter { $0.value.type == firstSyncType }.sorted { $0.key < $1.key }
            .compactMap { name, item in
                (try? SyncBody.decoder().decode(FirstSync.self, from: item.payload)).map { (dates[name] ?? now, $0) }
            }
        guard syncs.count > 1 else { return [:] }
        func current(_ item: FirstSyncItem) -> FirstSyncItem? {
            if let record = records[item.n] { return matchItem(item.n, record.body) }
            return asSent ? item : nil
        }
        var kept: [String: String] = [:]
        func canonical(_ name: String) -> String {
            var name = name, seen: Set<String> = []
            while let next = kept[name], seen.insert(name).inserted { name = next }
            return name
        }
        func id(_ name: String) -> String { SyncName.id(name)?.uuidString ?? name }
        for i in syncs.indices {
            for j in syncs.indices where j > i && abs(syncs[i].0.timeIntervalSince(syncs[j].0)) <= firstSyncsAtOnce {
                for kind in ["profile", "space", "folder", "folder", "folder", "folder", "page", "favorite"] {
                    func groups(_ sync: FirstSync) -> [String: [String]] {
                        var result: [String: [String]] = [:]
                        for listed in sync.items where listed.n.hasPrefix(kind + ".") && kept[listed.n] == nil {
                            guard let item = current(listed) else { continue }
                            result["\(item.p.map(canonical)) \(item.k)", default: []].append(item.n)
                        }
                        return result.mapValues { $0.sorted { id($0) < id($1) } }
                    }
                    let a = groups(syncs[i].1), b = groups(syncs[j].1)
                    for (key, mine) in a {
                        guard let theirs = b[key] else { continue }
                        for (x, y) in zip(mine, theirs) where x != y {
                            let (keep, drop) = id(x) < id(y) ? (x, y) : (y, x)
                            kept[drop] = keep
                        }
                    }
                }
            }
        }
        return kept
    }

    /// Copies from two first syncs at once dropped here, what was in them moved to the one kept. Each pair waits only
    /// until the one kept has arrived.
    private func dropCopies() {
        let pairs = Self.copies(in: state.base, dates: state.serverDates, now: now())
        guard !pairs.isEmpty else { return }
        let own = state.ownFirstSync.flatMap { name in
            state.base[name].flatMap { try? SyncBody.decoder().decode(FirstSync.self, from: $0.payload) }.map { Set($0.items.map(\.n)) }
        } ?? []
        var moved: [UUID: UUID] = [:]
        var deletes: [String] = []
        var profilesGone: [UUID] = []
        for (drop, keep) in pairs where state.base[drop] != nil && state.base[keep] != nil {
            guard let dropID = SyncName.id(drop), let keepID = SyncName.id(keep) else { continue }
            // This Mac's own copy: its item here goes on as the kept one. The other Mac's, made a profile here
            // moments ago, goes.
            let mine = state.aliases.local(dropID), theirs = state.aliases.local(keepID)
            if own.contains(drop) {
                state.aliases.link(local: mine, server: keepID)
                // The kept one, made a profile here when it arrived: this Mac's goes on as it.
                if drop.hasPrefix("profile."), theirs != mine { profilesGone.append(theirs) }
            } else if drop.hasPrefix("profile."), mine != theirs {
                profilesGone.append(mine)
            }
            state.base[drop] = nil
            state.unsent.remove(drop)
            state.copies.insert(drop)
            deletes.append(drop)
            moved[dropID] = keepID
        }
        guard !moved.isEmpty else { return }
        var saves: [String] = []
        let stamp = now()
        for (name, item) in state.base {
            guard let body = Self.moving(item.body, moved) else { continue }
            state.base[name] = SyncItem(body, modified: stamp)
            state.unsent.insert(name)
            saves.append(name)
        }
        queue((saves, deletes))
        if !profilesGone.isEmpty {
            var library = host.read()
            for id in profilesGone where id != Profile.defaultID { _ = library.contents.directory.remove(id) }
            write(library)
        }
    }

    /// The body with references to `map`'s keys moved to its values, or nil when it has none.
    private static func moving(_ body: SyncBody, _ map: [UUID: UUID]) -> SyncBody? {
        guard !map.isEmpty else { return nil }
        func m(_ id: UUID) -> UUID { map[id] ?? id }
        func splits(_ list: [PinnedSplit]) -> [PinnedSplit] {
            list.compactMap { split in split.layout.withPages(split.ids.map(m)).map(PinnedSplit.init(layout:)) }
        }
        func touches(_ ids: [UUID?]) -> Bool { ids.contains { $0.map { map[$0] != nil } ?? false } }
        switch body {
        case .page(var p):
            guard touches([p.space, p.parent]) else { return nil }
            p.space = m(p.space); p.parent = p.parent.map(m)
            return .page(p)
        case .folder(var f):
            guard touches([f.space, f.parent]) else { return nil }
            f.space = m(f.space); f.parent = f.parent.map(m)
            return .folder(f)
        case .favorite(var f):
            guard touches([f.profile]) else { return nil }
            f.profile = m(f.profile)
            return .favorite(f)
        case .space(var s):
            guard touches([s.profile] + s.splits.flatMap(\.ids)) else { return nil }
            s.profile = m(s.profile); s.splits = splits(s.splits)
            return .space(s)
        case .profile(var p):
            guard touches(p.favoriteSplits.flatMap(\.ids)) else { return nil }
            p.favoriteSplits = splits(p.favoriteSplits)
            return .profile(p)
        case .rules(var r):
            guard touches(r.routes.rules.map(\.spaceID)) else { return nil }
            for i in r.routes.rules.indices { r.routes.rules[i].spaceID = m(r.routes.rules[i].spaceID) }
            return .rules(r)
        case .settings(let s):
            var values: [String: SyncSettings.Entry] = [:]
            var changed = false
            for (key, entry) in s.values {
                let renamed = SyncPreferences.renamed(key, m)
                changed = changed || renamed != key
                values[renamed] = entry
            }
            return changed ? .settings(SyncSettings(values: values)) : nil
        default:
            return nil
        }
    }

    // MARK: Sending

    /// iCloud takes a record up to 1 MB, its own fields included.
    static let largestPayload = 900_000

    /// The record to send for `name`, or nil when there's nothing to send (it was removed here since), or it's too big
    /// for iCloud and stays on this Mac until it's smaller.
    func upload(_ name: String) -> SyncUpload? {
        guard let item = state.base[name] else { return nil }
        if case .unknown = item.body, item.type != Self.firstSyncType { return nil }
        let payload = SyncBody.overlay(item.payload, on: state.serverPayloads[name], type: item.type)
        guard payload.count <= Self.largestPayload else { return nil }
        return SyncUpload(name: name, type: item.type, payload: payload, modified: item.modified, systemFields: state.systemFields[name])
    }

    func saved(_ records: [SyncRemote]) {
        guard !isClosed else { return }
        for record in records {
            state.systemFields[record.name] = record.systemFields
            state.serverPayloads[record.name] = record.payload
            if let date = record.serverModified { state.serverDates[record.name] = date }
            if let item = state.base[record.name], item.modified == record.modified { state.unsent.remove(record.name) }
        }
        state.lastSynced = now()
        onChange?()
    }

    func deleteFailed(_ name: String, _ failure: SyncDeleteFailure) {
        switch failure {
        case .gone:
            deleted([name])
        case .zoneMissing:
            if state.merged { onRemovedElsewhere?() } else { deleted([name]) }
        }
    }

    /// A save that found the record gone, once iCloud's removals have been read: removed after it changed here (a Mac
    /// restored from a backup), the removal wins; removed while it changed here, the change wins and it comes back.
    private func decideGone(_ name: String) {
        state.goneAsked.remove(name)
        state.goneRead.remove(name)
        if let at = removedAt(name), let edit = state.base[name]?.modified, at > edit {
            state.base[name] = nil
            state.unsent.remove(name)
            state.systemFields[name] = nil
            state.serverPayloads[name] = nil
            layOut()
            return
        }
        state.systemFields[name] = nil
        state.serverPayloads[name] = nil
        if state.base[name] != nil { state.unsent.insert(name); queue(([name], [])) }
    }

    func deleted(_ names: [String]) {
        guard !isClosed else { return }
        for name in names where state.base[name] == nil {
            state.systemFields[name] = nil
            state.serverPayloads[name] = nil
            state.serverDates[name] = nil
        }
        onChange?()
    }

    func saveFailed(_ name: String, _ failure: SyncSaveFailure) {
        guard !isClosed else { return }
        switch failure {
        case .conflict(let record):
            arrive(name, record)
            if state.merged { settle() }
        case .conflictUnread:
            // Stays unsent, so it goes up again once the fetch has merged it.
            if state.base[name] != nil { state.unsent.insert(name) }
            onNeedsFetch?()
        case .gone:
            // When it was removed isn't known here yet: read iCloud's removals first, then decide.
            guard removedAt(name) != nil || state.goneRead.contains(name) else {
                state.goneAsked.insert(name)
                onNeedsFetch?()
                break
            }
            decideGone(name)
        case .zoneMissing:
            // After the first sync it was removed, never made again from here.
            if state.merged { onRemovedElsewhere?(); return }
            state.systemFields = [:]
            state.unsent.formUnion(state.base.keys)
            queue((Array(state.base.keys), []))
        }
        onChange?()
    }

    /// Everything here goes up again from scratch (iCloud's copy was reset): merged again on the next fetch.
    func startOver() {
        let account = state.account, aliases = state.aliases, wait = state.firstSyncWait
        state = SyncState()
        state.account = account
        state.aliases = aliases
        state.firstSyncWait = wait
        clearIncoming()
        onChange?()
    }
}

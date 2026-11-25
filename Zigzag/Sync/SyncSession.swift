import Foundation

/// Where sync reads and writes the library: Zigzag's own, or a test's.
protocol SyncHost: AnyObject {
    func read() -> SyncLibrary
    func write(_ library: SyncLibrary)
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
    /// It was removed from the server since.
    case gone
    /// The zone isn't there (removed, or never made).
    case zoneMissing
}

/// A favorite or a preference of a profile, removed on another Mac before the profile itself was.
struct SyncLeftover: Codable {
    var at: Date
    var favorite: SyncItem?
    var value: SettingValue?
    /// How long one waits for its profile's removal.
    static let kept: TimeInterval = 30 * 24 * 3600
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
    /// Favorites (by record name) and preferences (by key) of another profile removed elsewhere lately: when the
    /// profile's own removal follows, they come back with it.
    var leftovers: [String: SyncLeftover] = [:]
    /// How many removals made here at once wait to be confirmed or brought back; nil while nothing waits.
    var heldRemovals: Int?
    /// How far Zigzag's own fetch of the zone has read, beside CKSyncEngine's.
    var zoneToken: Data?

    private enum CodingKeys: String, CodingKey {
        case base, serverPayloads, systemFields, unsent, aliases, emptyFolders, merged, account, lastSynced, engine, keptProfiles
        case incoming, incomingRemoved, serverDates, zoneToken, leftovers, heldRemovals
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
        heldRemovals = try c.decodeIfPresent(Int.self, forKey: .heldRemovals)
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
    /// True while it writes into the library, so the change that causes isn't read as one made here.
    private(set) var isApplying = false

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

    /// Reads the library and queues what changed since.
    func localChanged(allowingManyRemovals: Bool = false) {
        guard state.merged, !isApplying, state.heldRemovals == nil else { return }
        let export = SyncMapping.export(host.read(), previous: state.base, aliases: state.aliases, emptyBefore: state.emptyFolders,
                                        kept: state.keptProfiles, unsent: state.unsent, now: now())
        if !allowingManyRemovals, let count = Self.manyRemovals(from: state.base, to: export.items) {
            state.heldRemovals = count
            onChange?()
            onHeld?()
            return
        }
        state.emptyFolders = export.emptyFolders
        queue(diff(export.items, deletes: true))
        onChange?()
        if export.needsLayout { layOut() }
    }

    /// More than 10 of one kind, and more than a quarter of them, gone at once: a library file replaced or rolled
    /// back (Time Machine, an old copy) rather than things removed by hand. Returns how many.
    static func manyRemovals(from base: [String: SyncItem], to items: [String: SyncItem]) -> Int? {
        var total: [Substring: Int] = [:], gone: [Substring: Int] = [:]
        for name in base.keys where SyncName.id(name) != nil {
            let kind = name.prefix { $0 != "." }
            total[kind, default: 0] += 1
            if items[name] == nil { gone[kind, default: 0] += 1 }
        }
        let many = gone.filter { kind, count in count > 10 && Double(count) > Double(total[kind] ?? 0) * 0.25 }
        return many.isEmpty ? nil : gone.values.reduce(0, +)
    }

    /// Held removals brought back: what iCloud has is laid out here again, and what else changed here meanwhile goes up.
    func bringBackHeld() {
        guard state.heldRemovals != nil else { return }
        state.heldRemovals = nil
        let export = SyncMapping.export(host.read(), previous: state.base, aliases: state.aliases, emptyBefore: state.emptyFolders,
                                        kept: state.keptProfiles, unsent: state.unsent, now: now())
        queue(diff(export.items, deletes: false))
        layOut()
        fetchFinished()
        onHeld?()
    }

    /// Held removals sent: removed from iCloud, and so from every Mac.
    func sendHeld() {
        guard state.heldRemovals != nil else { return }
        state.heldRemovals = nil
        localChanged(allowingManyRemovals: true)
        fetchFinished()
        onHeld?()
    }

    /// Everything the server hasn't confirmed, from the state rather than the server's own queue: edits made while
    /// there was no server (offline, before connecting) and what a quit before the server saved its queue lost.
    func requeue() {
        let deletes = state.serverPayloads.keys.filter { state.base[$0] == nil }
        queue((Array(state.unsent), deletes))
    }

    private func queue(_ changes: (saves: [String], deletes: [String])) {
        guard !changes.saves.isEmpty || !changes.deletes.isEmpty else { return }
        server?.queue(saves: SyncName.ordered(changes.saves), deletes: SyncName.ordered(changes.deletes))
    }

    private func diff(_ exported: [String: SyncItem], deletes allowDeletes: Bool) -> (saves: [String], deletes: [String]) {
        let items = exported
        var saves: [String] = [], deletes: [String] = []
        let stamp = now()
        for (name, var item) in items {
            if let old = state.base[name], old.sameContent(as: item) { continue }
            if item.type != SyncBody.settingsType { item.modified = stamp }
            state.base[name] = item
            state.unsent.insert(name)
            saves.append(name)
        }
        if allowDeletes {
            for (name, item) in state.base where items[name] == nil {
                // A kind only a newer Zigzag reads is left as it is.
                if case .unknown = item.body { continue }
                state.base[name] = nil
                state.unsent.remove(name)
                deletes.append(name)
            }
        }
        return (saves, deletes)
    }

    /// The library laid out from the records, then read back: what that changed (a page whose folder is gone, now
    /// at the top of its space) goes up too.
    private func layOut() {
        isApplying = true
        host.write(SyncMapping.apply(state.base, onto: host.read(), aliases: state.aliases, kept: state.keptProfiles, unsent: state.unsent).library)
        isApplying = false
        localChanged()
    }

    // MARK: Changes from the server

    func fetched(_ records: [SyncRemote], deleted: [String]) {
        for record in records { arrive(record.name, record) }
        for name in deleted { arrive(name, nil) }
        if !records.isEmpty || !deleted.isEmpty { onChange?() }
    }

    /// A fetch is done: the first sync merges, later ones settle what came.
    func fetchFinished() {
        // While removals are held, what comes waits too: laying it out would bring them back unasked.
        if state.heldRemovals != nil { onChange?(); return }
        if !state.merged { mergeFirst() } else { settle() }
        state.lastSynced = now()
        onChange?()
    }

    private func settle() {
        guard !state.incoming.isEmpty || !state.incomingRemoved.isEmpty else { return }
        // What changed here first, so it isn't taken for something the server undid.
        localChanged()
        guard state.heldRemovals == nil else { return }
        let arrived = incoming
        clearIncoming()
        var changed = false
        var resend: [String] = []
        var profilesGone: Set<UUID> = []
        let stamp = now()
        state.leftovers = state.leftovers.filter { stamp.timeIntervalSince($0.value.at) < SyncLeftover.kept }
        for (name, record) in arrived {
            if let record {
                let outcome = take(record)
                changed = changed || outcome.changed
                if outcome.resend { resend.append(name) }
            } else {
                state.systemFields[name] = nil
                state.serverPayloads[name] = nil
                state.serverDates[name] = nil
                // Changed here since: it comes back rather than vanish.
                if state.unsent.contains(name) { resend.append(name); continue }
                if let item = state.base.removeValue(forKey: name) {
                    // A profile removed elsewhere stays here, never its data erased: it's this Mac's own from now on.
                    if name.hasPrefix("profile."), let id = SyncName.id(name).map(state.aliases.local), id != Profile.defaultID {
                        state.keptProfiles.insert(id)
                        profilesGone.insert(id)
                    }
                    // Another profile's favorite: kept a while, in case its profile's removal comes next.
                    if case .favorite(let favorite) = item.body, favorite.profile != Profile.defaultID {
                        state.leftovers[name] = SyncLeftover(at: stamp, favorite: item)
                    }
                    changed = true
                }
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
                state.leftovers["setting:" + key] = SyncLeftover(at: stamp, value: value)
            }
        }
        if !profilesGone.isEmpty { bringBack(profilesGone) }
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
        isApplying = true
        host.write(library)
        isApplying = false
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
    private func mergeFirst() {
        var server: [String: SyncItem] = [:]
        for case let (name, record?) in incoming {
            if let date = record.serverModified { state.serverDates[name] = date }
            state.systemFields[name] = record.systemFields
            state.serverPayloads[name] = record.payload
            server[name] = SyncItem(SyncBody.decode(type: record.type, payload: record.payload), modified: record.modified)
        }
        clearIncoming()
        let merge = SyncMerge.merge(local: host.read(), server: server, now: now())
        state.aliases = merge.aliases
        state.base = server
        state.merged = true
        isApplying = true
        host.write(SyncMapping.apply(merge.items, onto: host.read(), aliases: state.aliases).library)
        isApplying = false
        let export = SyncMapping.export(host.read(), previous: state.base, aliases: state.aliases, now: now())
        state.emptyFolders = export.emptyFolders
        // Nothing in iCloud is removed because this Mac lacks it.
        queue(diff(export.items, deletes: false))
    }

    // MARK: Sending

    /// iCloud takes a record up to 1 MB, its own fields included.
    static let largestPayload = 900_000

    /// The record to send for `name`, or nil when there's nothing to send (it was removed here since), or it's too big
    /// for iCloud and stays on this Mac until it's smaller.
    func upload(_ name: String) -> SyncUpload? {
        guard let item = state.base[name] else { return nil }
        if case .unknown = item.body { return nil }
        let payload = SyncBody.overlay(item.payload, on: state.serverPayloads[name], type: item.type)
        guard payload.count <= Self.largestPayload else { return nil }
        return SyncUpload(name: name, type: item.type, payload: payload, modified: item.modified, systemFields: state.systemFields[name])
    }

    func saved(_ records: [SyncRemote]) {
        for record in records {
            state.systemFields[record.name] = record.systemFields
            state.serverPayloads[record.name] = record.payload
            if let date = record.serverModified { state.serverDates[record.name] = date }
            if let item = state.base[record.name], item.modified == record.modified { state.unsent.remove(record.name) }
        }
        state.lastSynced = now()
        onChange?()
    }

    func deleted(_ names: [String]) {
        for name in names where state.base[name] == nil {
            state.systemFields[name] = nil
            state.serverPayloads[name] = nil
            state.serverDates[name] = nil
        }
        onChange?()
    }

    func saveFailed(_ name: String, _ failure: SyncSaveFailure) {
        switch failure {
        case .conflict(let record):
            arrive(name, record)
            if state.merged { settle() }
        case .gone:
            // Removed elsewhere while it changed here: the change wins and it comes back.
            state.systemFields[name] = nil
            state.serverPayloads[name] = nil
            if state.base[name] != nil { state.unsent.insert(name); queue(([name], [])) }
        case .zoneMissing:
            state.systemFields = [:]
            state.unsent.formUnion(state.base.keys)
            queue((Array(state.base.keys), []))
        }
        onChange?()
    }

    /// Everything here goes up again from scratch (iCloud's copy was reset): merged again on the next fetch.
    func startOver() {
        let account = state.account
        state = SyncState()
        state.account = account
        clearIncoming()
        onChange?()
    }
}

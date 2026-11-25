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
    func fetchChanges() async throws
    func sendChanges() async throws
}

/// A record as the server has it.
struct SyncRemote {
    var name: String
    var type: String
    /// Its fields as the server holds them, a newer Zigzag's included.
    var payload: Data
    var modified: Date
    /// The server's own fields (its change tag), handed back with the next save so a stale one is caught.
    var systemFields: Data?
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

    private enum CodingKeys: String, CodingKey {
        case base, serverPayloads, systemFields, unsent, aliases, emptyFolders, merged, account, lastSynced, engine, keptProfiles
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
    /// True while it writes into the library, so the change that causes isn't read as one made here.
    private(set) var isApplying = false

    /// What the server sent since the last settle: a record, or nil for one removed.
    private var incoming: [String: SyncRemote?] = [:]

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
    func localChanged() {
        guard state.merged, !isApplying else { return }
        let export = SyncMapping.export(host.read(), previous: state.base, aliases: state.aliases, emptyBefore: state.emptyFolders,
                                        kept: state.keptProfiles, now: now())
        state.emptyFolders = export.emptyFolders
        queue(diff(export.items, deletes: true))
        onChange?()
        if export.needsLayout { layOut() }
    }

    private func queue(_ changes: (saves: [String], deletes: [String])) {
        guard !changes.saves.isEmpty || !changes.deletes.isEmpty else { return }
        server?.queue(saves: changes.saves.sorted(), deletes: changes.deletes.sorted())
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
        host.write(SyncMapping.apply(state.base, onto: host.read(), aliases: state.aliases, kept: state.keptProfiles).library)
        isApplying = false
        localChanged()
    }

    // MARK: Changes from the server

    func fetched(_ records: [SyncRemote], deleted: [String]) {
        for record in records { incoming[record.name] = .some(record) }
        for name in deleted { incoming[name] = .some(nil) }
    }

    /// A fetch is done: the first sync merges, later ones settle what came.
    func fetchFinished() {
        if !state.merged { mergeFirst() } else { settle() }
        state.lastSynced = now()
        onChange?()
    }

    private func settle() {
        guard !incoming.isEmpty else { return }
        // What changed here first, so it isn't taken for something the server undid.
        localChanged()
        let arrived = incoming
        incoming = [:]
        var changed = false
        var resend: [String] = []
        for (name, record) in arrived {
            if let record {
                let outcome = take(record)
                changed = changed || outcome.changed
                if outcome.resend { resend.append(name) }
            } else {
                state.systemFields[name] = nil
                state.serverPayloads[name] = nil
                // Changed here since: it comes back rather than vanish.
                if state.unsent.contains(name) { resend.append(name); continue }
                if state.base.removeValue(forKey: name) != nil {
                    // A profile removed elsewhere stays here, never its data erased: it's this Mac's own from now on.
                    if name.hasPrefix("profile."), let id = SyncName.id(name).map(state.aliases.local), id != Profile.defaultID {
                        state.keptProfiles.insert(id)
                    }
                    changed = true
                }
            }
        }
        queue((resend, []))
        if changed { layOut() }
    }

    /// The server's version of a record meets this Mac's. Returns whether the library changes, and whether this
    /// Mac's version still has to go up.
    private func take(_ record: SyncRemote) -> (changed: Bool, resend: Bool) {
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
        let resolved = Self.resolve(mine, theirs)
        if resolved.sameContent(as: theirs) {
            state.base[record.name] = theirs
            state.unsent.remove(record.name)
            return (!mine.sameContent(as: theirs), false)
        }
        state.base[record.name] = resolved
        return (!mine.sameContent(as: resolved), true)
    }

    /// Last writer wins, by date; a tie goes to the server's. Preferences meet key by key.
    static func resolve(_ mine: SyncItem, _ theirs: SyncItem) -> SyncItem {
        if case .settings(let a) = mine.body, case .settings(let b) = theirs.body {
            let values = SyncSettings.merged(b.values, a.values)
            return SyncItem(.settings(SyncSettings(values: values)), modified: max(mine.modified, theirs.modified))
        }
        return mine.modified > theirs.modified ? mine : theirs
    }

    /// The first sync on this Mac: iCloud's records and the library here merged, never replaced.
    private func mergeFirst() {
        var server: [String: SyncItem] = [:]
        for case let (name, record?) in incoming {
            state.systemFields[name] = record.systemFields
            state.serverPayloads[name] = record.payload
            server[name] = SyncItem(SyncBody.decode(type: record.type, payload: record.payload), modified: record.modified)
        }
        incoming = [:]
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
            if let item = state.base[record.name], item.modified == record.modified { state.unsent.remove(record.name) }
        }
        state.lastSynced = now()
        onChange?()
    }

    func deleted(_ names: [String]) {
        for name in names where state.base[name] == nil {
            state.systemFields[name] = nil
            state.serverPayloads[name] = nil
        }
        onChange?()
    }

    func saveFailed(_ name: String, _ failure: SyncSaveFailure) {
        switch failure {
        case .conflict(let record):
            incoming[name] = .some(record)
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
        incoming = [:]
        onChange?()
    }
}

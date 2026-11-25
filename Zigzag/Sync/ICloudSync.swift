import AppKit
import CloudKit
import Network
import os

/// Settings › General › Sync with iCloud: spaces, profiles, pinned pages, folders, favorites, live folders and
/// preferences through the private database of your own iCloud, with CKSyncEngine. Off by default; while it's off
/// nothing here touches CloudKit.
final class ICloudSync {
    static let shared = ICloudSync()

    static let containerID = "iCloud.wang.zigao.zigzag"
    static let zoneID = CKRecordZone.ID(zoneName: "Library", ownerName: CKCurrentUserDefaultName)
    /// On or off; never synced itself.
    static let enabledKey = "SyncWithICloud"
    private static let log = Logger(subsystem: "wang.zigao.zigzag", category: "sync")

    enum Status: Equatable {
        case off
        case syncing
        case synced(Date?)
        case notSignedIn
        case otherAccount
        case restricted
        case full
        case offline
        case removedElsewhere
        case notEntitled
        /// Turning it on couldn't save the backup first, so it stayed off.
        case backupFailed
        case failed(String)
    }

    private(set) var status: Status = .off { didSet { if oldValue != status { changed.send() } } }
    /// Fires when the status changes.
    let changed = Signal<Void>()

    var isOn: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// iCloud has a copy from this Mac, so Remove from iCloud… still means something while sync is off.
    static let copyKey = "SyncWithICloudCopy"
    var hasCopy: Bool { UserDefaults.standard.bool(forKey: Self.copyKey) }

    /// Whether this build may use the container: one signed without it would stop at CKContainer.
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) else { return false }
        return (value as? [String])?.contains(containerID) == true
    }

    private var session: SyncSession?
    private var engine: CloudEngine?
    private let host = AppSyncHost()
    private var tokens: [SignalToken] = []
    private var observers: [NSObjectProtocol] = []
    private let localDebouncer = Debouncer(delay: 1, maxWait: 10)
    private let saveDebouncer = Debouncer(delay: 1, maxWait: 10)
    private var timer: Timer?
    private var lastFetch = Date.distantPast
    private var connecting = false
    /// A fetch or send that failed is tried again on its own.
    let retry = SyncRetry()
    private var network: NWPathMonitor?
    private var reachable: Bool?

    private static var stateFile: URL { Paths.directory("Sync").appendingPathComponent("State.json") }

    private init() {
        retry.onRetry = { [weak self] in self?.tryAgain() }
    }

    // MARK: Starting and stopping

    /// At launch: picks up where it was, when it's on.
    func startIfOn() {
        guard isOn, session == nil else { return }
        let library = Library.shared
        start(state: Self.stateAtLaunch(saved: JSONStore.load(SyncState.self, from: Self.stateFile) ?? SyncState(),
                                        libraryWasRead: library.wasRead && !library.profilesWereSetAside))
    }

    /// What sync starts from at launch. A library that couldn't be read (and started afresh) is merged with iCloud as
    /// on a first sync, so iCloud fills it in rather than its missing spaces being removed from every Mac. A first
    /// sync that didn't finish reads all of iCloud again, not only what changed since it was cut short.
    static func stateAtLaunch(saved: SyncState, libraryWasRead: Bool) -> SyncState {
        var state = saved
        if !libraryWasRead {
            state = SyncState()
            state.account = saved.account
        }
        if !state.merged { state.engine = nil }
        return state
    }

    /// Turned on in Settings: a backup first, then the first sync merges this Mac's library with iCloud's. Without the
    /// backup (a full disk), it stays off.
    func turnOn(backingUp: () -> URL? = { ICloudSync.shared.backUp() }) {
        guard !isOn else { return }
        guard backingUp() != nil else { status = .backupFailed; return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        stop()
        try? FileManager.default.removeItem(at: Self.stateFile)
        start(state: SyncState())
    }

    /// Turned off: everything stays on this Mac, and iCloud keeps its copy.
    func turnOff() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        stop()
        try? FileManager.default.removeItem(at: Self.stateFile)
        status = .off
    }

    /// Remove from iCloud…: the synced copy goes from iCloud, for every Mac; this Mac keeps its own, and sync turns off.
    func removeFromICloud() async -> Bool {
        guard Self.isEntitled else { status = .notEntitled; return false }
        // Stopped first, so nothing makes the zone again on its way out.
        stop()
        let container = CKContainer(identifier: Self.containerID)
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [Self.zoneID])
        } catch let error as CKError where error.code == .zoneNotFound {
        } catch {
            Self.log.error("removing the zone failed: \(error.localizedDescription, privacy: .public)")
            startIfOn()
            status = Self.status(for: error) ?? .failed(error.localizedDescription)
            return false
        }
        turnOff()
        UserDefaults.standard.set(false, forKey: Self.copyKey)
        return true
    }

    private func start(state: SyncState) {
        let session = SyncSession(host: host, state: state)
        session.onChange = { [weak self] in self?.saveSoon() }
        self.session = session
        watchLibrary()
        status = .syncing
        Task { await connect() }
    }

    private func stop() {
        saveNow()
        engine?.stop()
        engine = nil
        session = nil
        tokens = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timer?.invalidate()
        timer = nil
        network?.cancel()
        network = nil
        retry.reset()
    }

    /// Checks the account before anything goes up: a different one than before pauses until sync is turned on again.
    private func connect() async {
        guard Self.isEntitled else { status = .notEntitled; return }
        // One engine at a time.
        guard !connecting, engine == nil else { return }
        connecting = true
        defer { connecting = false }
        let container = CKContainer(identifier: Self.containerID)
        do {
            switch try await container.accountStatus() {
            case .available: break
            // Signing in, or iCloud allowed again, posts CKAccountChanged.
            case .noAccount: status = .notSignedIn; return
            case .restricted: status = .restricted; return
            default: status = .offline; retry.failed(nil); return
            }
            let user = try await container.userRecordID().recordName
            guard let session, isOn else { return }
            guard Self.mayUse(account: user, saved: session.state.account) else { status = .otherAccount; return }
            session.updateState { $0.account = user }
            let engine = CloudEngine(container: container, session: session, owner: self)
            self.engine = engine
            session.server = engine
            engine.start()
            await catchUp()
        } catch {
            Self.log.error("connecting failed: \(error.localizedDescription, privacy: .public)")
            failed(error)
        }
    }

    /// Every connection and every fetch: the first sync's merge, or what changed elsewhere while this Mac was away;
    /// then what's waiting here goes up.
    private func catchUp() async {
        guard let engine, let session else { return }
        lastFetch = Date()
        do {
            try await Self.catchUp(session, through: engine, isCurrent: { [weak self] in self?.session === session }) { [weak self] first in
                guard let self else { return }
                if first {
                    UserDefaults.standard.set(true, forKey: Self.copyKey)
                    status = .synced(session.state.lastSynced)
                }
                retry.succeeded()
            }
        } catch {
            Self.log.error("syncing failed: \(error.localizedDescription, privacy: .public)")
            guard self.session === session else { return }
            if Self.isZoneGone(error) {
                zoneMissing(error)
                return
            }
            failed(error)
        }
    }

    /// A fetch, merged as the first sync when it hasn't been yet, then a send. The first sync merges only once
    /// everything in iCloud has been read; later fetches settle as their changes arrive.
    static func catchUp(_ session: SyncSession, through server: SyncTransport, isCurrent: () -> Bool = { true },
                        fetched: (_ first: Bool) -> Void = { _ in }) async throws {
        do {
            try await server.fetchChanges(.zone)
        } catch where isZoneGone(error) && !session.state.merged {
            // No zone yet before the first sync: iCloud has nothing, and the send makes it.
        }
        guard isCurrent() else { return }
        let first = !session.state.merged
        if first { session.fetchFinished() }
        fetched(first)
        try await server.sendChanges()
    }

    /// The status for a failure, and the next try unless waiting won't help.
    private func failed(_ error: Error) {
        status = Self.status(for: error) ?? (SyncRetry.isPermanent(error) ? .failed(error.localizedDescription) : .offline)
        retry.failed(error)
    }

    /// What failed is tried again: connecting, the first sync, or a fetch and what's waiting to go up.
    private func tryAgain() {
        guard isOn, session != nil else { return }
        lastFetch = Date()
        guard engine != nil else { Task { await connect() }; return }
        Task { await catchUp() }
    }

    private func watchLibrary() {
        tokens = [Library.shared.changed.observe { [weak self] in self?.localChangedSoon() }]
        observers = [
            NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.localChangedSoon() }
            },
            // Without a push, a Mac coming back to Zigzag still sees what changed.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fetchSoon(after: 60) }
            },
            // Signed in again, or into another account: checked before anything goes up.
            NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.accountChanged() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retry.soon() }
            },
        ]
        watchNetwork()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetchSoon(after: 5 * 60) }
        }
    }

    private func localChangedSoon() {
        guard let session, !session.isApplying, !host.isWriting else { return }
        localDebouncer.call { [weak self] in self?.session?.localChanged() }
    }

    /// A fetch when the last was at least `after` seconds ago.
    private func fetchSoon(after seconds: TimeInterval) {
        guard session != nil, Date().timeIntervalSince(lastFetch) > seconds else { return }
        lastFetch = Date()
        // Not connected yet (signed out, offline at launch), or the first sync didn't finish: tried again.
        guard engine != nil else { Task { await connect() }; return }
        Task { await catchUp() }
    }

    /// The network coming back tries again at once.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        reachable = nil
        monitor.pathUpdateHandler = { [weak self] path in
            let now = path.status == .satisfied
            MainActor.assumeIsolated {
                guard let self else { return }
                if now, self.reachable == false { self.retry.soon() }
                self.reachable = now
            }
        }
        monitor.start(queue: .main)
        network = monitor
    }

    // MARK: Saving the state

    private func saveSoon() { saveDebouncer.call { [weak self] in self?.saveNow() } }

    /// Before quitting, too.
    func saveNow() {
        saveDebouncer.cancel()
        guard let session else { return }
        var state = session.state
        if let engine { state.engine = engine.serialization ?? state.engine }
        JSONStore.save(state, to: Self.stateFile)
    }

    // MARK: Before the first sync

    /// A Zigzag backup of what's here now, in Backups, so a merge that wasn't wanted can be undone (File › Import).
    @discardableResult
    func backUp() -> URL? {
        let folder = Paths.directory("Backups")
        guard let data = try? ZigzagBackup.make(managers: [], openTabs: false, history: false).encoded() else { return nil }
        let url = DataExport.unusedFile(named: DataExport.backupName(), in: folder)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    // MARK: From the engine

    fileprivate func engineEvent(_ status: Status) { self.status = status }

    fileprivate func accountChanged() {
        // Signed out or another account: nothing more goes up or comes down; the library here stays.
        retry.reset()
        engine?.stop()
        engine = nil
        session?.server = nil
        Task { await connect() }
    }

    /// Our zone isn't in iCloud. Before the first sync that's an empty iCloud; after it, the zone was removed.
    fileprivate func zoneMissing(_ error: Error) {
        guard session?.state.merged == true else { return }
        zoneDeleted(reset: false)
    }

    static func isZoneGone(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .zoneNotFound || error.code == .userDeletedZone { return true }
        return error.partialErrorsByItemID?.values.contains { isZoneGone($0) } == true
    }

    fileprivate func zoneDeleted(reset: Bool) {
        if reset {
            // iCloud's copy was reset (its encryption keys): this Mac's library goes up again, merged as on a first sync.
            session?.startOver()
            engine?.stop()
            engine = nil
            Task { await connect() }
        } else {
            // Remove from iCloud on another Mac, or iCloud's data deleted in System Settings: sync stops here too, and
            // the library here stays.
            turnOff()
            UserDefaults.standard.set(false, forKey: Self.copyKey)
            status = .removedElsewhere
        }
    }

    /// Only the account sync was turned on with: another one waits until sync is turned on again, and asked.
    static func mayUse(account: String, saved: String?) -> Bool { saved.map { $0 == account } ?? true }

    static func status(for error: Error) -> Status? {
        guard let error = error as? CKError else { return nil }
        switch error.code {
        case .notAuthenticated: return .notSignedIn
        case .quotaExceeded: return .full
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .serverRejectedRequest, .internalError, .serverResponseLost: return .offline
        case .managedAccountRestricted: return .restricted
        default: return nil
        }
    }
}

// MARK: - Trying again

/// A fetch or send that failed is tried again: after 30 seconds, then twice as long each time up to 30 minutes, a
/// little sooner at random so Macs don't all ask at once, and never sooner than iCloud asks. The network coming back
/// or the Mac waking tries at once. An error that waiting won't fix waits for one of those, or for the account.
final class SyncRetry {
    static let first: TimeInterval = 30
    static let longest: TimeInterval = 30 * 60
    /// A try at once still waits this long after the last, so a flapping network isn't a loop.
    static let shortest: TimeInterval = 5

    /// Runs the work after the delay and returns what cancels it; tests run it by hand.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { delay, work in
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
    /// A share of the wait, from 0.8 to 1.
    var jitter: () -> Double = { .random(in: 0.8...1) }
    var now: () -> Date = Date.init
    /// The try itself.
    var onRetry: (() -> Void)?

    /// Failures in a row since the last success.
    private(set) var failures = 0
    /// Stopped by an error waiting won't fix.
    private(set) var isStopped = false
    private var cancelPending: (() -> Void)?
    private var lastTry = Date.distantPast
    var isWaiting: Bool { cancelPending != nil }

    /// The wait before the next try after `failures` failures in a row.
    static func delay(afterFailures failures: Int, retryAfter: TimeInterval? = nil, jitter: Double = 1) -> TimeInterval {
        let doubled = first * pow(2, Double(max(0, min(failures - 1, 16))))
        return max(min(doubled, longest) * jitter, retryAfter ?? 0)
    }

    /// Waiting won't fix these: they show their status and wait for the account, the network or a wake.
    static func isPermanent(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .notAuthenticated, .managedAccountRestricted, .quotaExceeded, .incompatibleVersion, .badContainer,
             .badDatabase, .missingEntitlement, .permissionFailure:
            return true
        default:
            return false
        }
    }

    /// After a failure (nil for one without an error, like an account iCloud can't check yet): the wait before the
    /// next try, or nil when there's none.
    @discardableResult
    func failed(_ error: Error?) -> TimeInterval? {
        cancel()
        if let error, Self.isPermanent(error) {
            isStopped = true
            return nil
        }
        isStopped = false
        failures += 1
        let delay = Self.delay(afterFailures: failures, retryAfter: (error as? CKError)?.retryAfterSeconds, jitter: jitter())
        wait(delay)
        return delay
    }

    func succeeded() {
        cancel()
        failures = 0
        isStopped = false
    }

    /// The network came back or the Mac woke: what failed is tried now, without starting the waits over.
    func soon() {
        guard failures > 0 || isStopped else { return }
        cancel()
        wait(max(0, Self.shortest - now().timeIntervalSince(lastTry)))
    }

    /// Sync turned off or started again: nothing waits.
    func reset() { succeeded() }

    private func wait(_ delay: TimeInterval) {
        cancelPending = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelPending = nil
            self.lastTry = self.now()
            self.onRetry?()
        }
    }

    private func cancel() {
        cancelPending?()
        cancelPending = nil
    }
}

// MARK: - The library it reads and writes

/// Zigzag's own library and preferences, for sync.
final class AppSyncHost: SyncHost {
    /// While it writes, the library's change signal isn't one made here.
    private(set) var isWriting = false

    func read() -> SyncLibrary {
        let library = Library.shared
        return SyncLibrary(contents: library.contents, searchEngine: library.searchEngine,
                           settings: SyncPreferences.read(from: .standard, profiles: Set(library.profiles.map(\.id))))
    }

    func write(_ synced: SyncLibrary) {
        isWriting = true
        defer { isWriting = false }
        let library = Library.shared
        let before = read()
        library.applySynced(synced.contents)
        if synced.searchEngine != library.searchEngine { library.searchEngine = synced.searchEngine }
        var changes: [String: SettingValue?] = [:]
        for key in Set(before.settings.keys).union(synced.settings.keys) where before.settings[key] != synced.settings[key] {
            changes[key] = .some(synced.settings[key])
        }
        if !changes.isEmpty { SyncPreferences.write(changes, to: .standard) }
    }
}

// MARK: - CloudKit

/// CKSyncEngine on the private database, one zone. Records carry their fields as JSON (`payload`) and their date
/// (`modified`), so a newer Zigzag adds fields without a new schema.
final class CloudEngine: SyncServer, SyncTransport, CKSyncEngineDelegate {
    private let container: CKContainer
    private weak var session: SyncSession?
    private weak var owner: ICloudSync?
    private var engine: CKSyncEngine?
    private(set) var serialization: Data?
    private static let log = Logger(subsystem: "wang.zigao.zigzag", category: "sync")

    init(container: CKContainer, session: SyncSession, owner: ICloudSync) {
        self.container = container
        self.session = session
        self.owner = owner
        serialization = session.state.engine
    }

    func start() {
        let saved = serialization.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ICloudSync.zoneID))])
    }

    func stop() {
        engine = nil
    }

    func fetchChanges(_ scope: SyncFetchScope) async throws {
        switch scope {
        case .pending: try await engine?.fetchChanges()
        // Without a push the engine knows of no changed zone and asks nothing, so the zone is named.
        case .zone: try await engine?.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([ICloudSync.zoneID])))
        }
    }
    func sendChanges() async throws { try await engine?.sendChanges() }

    func queue(saves: [String], deletes: [String]) {
        let changes = saves.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: ICloudSync.zoneID)) }
            + deletes.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(CKRecord.ID(recordName: $0, zoneID: ICloudSync.zoneID)) }
        engine?.state.add(pendingRecordZoneChanges: changes)
    }

    // MARK: Records

    static let payloadField = "payload", modifiedField = "modified", formatField = "format"

    func record(for id: CKRecord.ID) -> CKRecord? {
        guard let upload = session?.upload(id.recordName) else { return nil }
        var record: CKRecord?
        if let fields = upload.systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) {
            coder.requiresSecureCoding = true
            record = CKRecord(coder: coder)
            coder.finishDecoding()
        }
        if record?.recordType != upload.type || record?.recordID != id { record = CKRecord(recordType: upload.type, recordID: id) }
        guard let record else { return nil }
        record[Self.payloadField] = upload.payload as NSData
        record[Self.modifiedField] = upload.modified as NSDate
        record[Self.formatField] = 1 as NSNumber
        return record
    }

    static func remote(_ record: CKRecord) -> SyncRemote {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return SyncRemote(name: record.recordID.recordName, type: record.recordType,
                          payload: (record[payloadField] as? Data) ?? Data("{}".utf8),
                          modified: (record[modifiedField] as? Date) ?? record.modificationDate ?? .distantPast,
                          systemFields: coder.encodedData)
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine, let session else { return }
        switch event {
        case .stateUpdate(let update):
            serialization = try? JSONEncoder().encode(update.stateSerialization)
            session.updateState { $0.engine = serialization }
        case .accountChange(let change):
            // The engine's first start reads as a sign-in: only another account, or none, stops it.
            switch change.changeType {
            case .signIn(let user):
                if !ICloudSync.mayUse(account: user.recordName, saved: session.state.account) { owner?.accountChanged() }
            case .signOut, .switchAccounts:
                owner?.accountChanged()
            @unknown default:
                owner?.accountChanged()
            }
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == ICloudSync.zoneID {
                owner?.zoneDeleted(reset: deletion.reason == .encryptedDataReset)
                return
            }
        case .didFetchRecordZoneChanges(let fetched):
            if fetched.zoneID == ICloudSync.zoneID, let error = fetched.error, ICloudSync.isZoneGone(error) { owner?.zoneMissing(error) }
        case .fetchedRecordZoneChanges(let changes):
            let records = changes.modifications.map(\.record).filter { $0.recordID.zoneID == ICloudSync.zoneID }.map(Self.remote)
            session.fetched(records, deleted: changes.deletions.filter { $0.recordID.zoneID == ICloudSync.zoneID }.map(\.recordID.recordName))
        case .sentRecordZoneChanges(let sent):
            session.saved(sent.savedRecords.map(Self.remote))
            session.deleted(sent.deletedRecordIDs.map(\.recordName))
            for failure in sent.failedRecordSaves {
                let name = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord { session.saveFailed(name, .conflict(Self.remote(server))) }
                case .zoneNotFound:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ICloudSync.zoneID))])
                    session.saveFailed(name, .zoneMissing)
                case .unknownItem:
                    session.saveFailed(name, .gone)
                case .quotaExceeded:
                    owner?.engineEvent(.full)
                    queue(saves: [name], deletes: [])
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
                    break
                default:
                    Self.log.error("a save failed: \(failure.error.localizedDescription, privacy: .public)")
                    owner?.engineEvent(.failed(failure.error.localizedDescription))
                }
            }
        case .willFetchChanges, .willSendChanges:
            owner?.engineEvent(.syncing)
        case .didFetchChanges:
            guard session.state.merged else { break }
            session.fetchFinished()
            owner?.retry.succeeded()
            owner?.engineEvent(.synced(session.state.lastSynced))
        case .didSendChanges:
            if session.state.merged, owner?.status == .syncing { owner?.engineEvent(.synced(session.state.lastSynced)) }
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] id in
            guard let record = await self?.record(for: id) else {
                // Nothing to send (removed here since, or too big for iCloud): dropped, so it isn't asked for again.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            return record
        }
    }
}

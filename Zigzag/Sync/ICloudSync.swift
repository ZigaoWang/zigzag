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
        /// Many things were removed here at once (an old copy of the library put back, say), counted by kind: they
        /// don't go up until asked whether to remove them everywhere or bring them back. With what sync is doing besides.
        indirect case removalsHeld([SyncKind: Int], Status)
        case failed(String)
    }

    var status: Status {
        guard let held = session?.state.heldNames, !held.isEmpty else { return shown }
        return .removalsHeld(SyncKind.count(held), shown)
    }
    private var shown: Status = .off { didSet { if oldValue != shown { changed.send() } } }
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
    private let pushDebouncer = Debouncer(delay: 1, maxWait: 5)
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
        watchPreferencesWhileOff()
        guard isOn, session == nil else { return }
        let library = Library.shared
        let saved = JSONStore.load(SyncState.self, from: Self.stateFile) ?? SyncState()
        start(state: Self.stateAtLaunch(saved: saved, libraryWasRead: Self.libraryWasRead(library.wasRead && !library.profilesWereSetAside,
                                                                                        profilesFile: library.profilesFileExisted, saved: saved),
                                        account: UserDefaults.standard.string(forKey: Self.accountKey)))
    }

    /// A Profiles.json that's gone while iCloud has this Mac's other profiles counts as unreadable, not as every
    /// profile removed: Zigzag writes it once there's a second profile and never deletes it.
    static func libraryWasRead(_ read: Bool, profilesFile: Bool, saved: SyncState) -> Bool {
        guard read else { return false }
        if profilesFile { return true }
        return !saved.base.contains { name, item in
            guard case .profile = item.body, let id = SyncName.id(name) else { return false }
            return saved.aliases.local(id) != Profile.defaultID && !saved.keptProfiles.contains(saved.aliases.local(id))
        }
    }

    /// Removals held: said in a toast too, not only in Settings, once the windows are up.
    private func tellHeld() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, case .removalsHeld = self.status,
                  let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            let text = SyncSettingsRows.describe(self.status, hasCopy: true).text
            let settings = String(localized: "Settings…", comment: "Zigzag menu item, and a command in the command bar.")
            controller.promptToast(text, symbol: "exclamationmark.icloud", duration: 12,
                                   action: (title: settings, run: { SettingsPage.open(.general, in: controller) }))
        }
    }

    /// A Library.json older than what was last synced: iCloud's version put back, said in a toast.
    private func tellTookICloud() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let controller = WindowManager.shared.keyController ?? WindowManager.shared.controllers.first else { return }
            controller.promptToast(String(localized: "This Mac’s library was older than what it last synced, so iCloud’s version was put back.",
                                          comment: "Toast at launch when Library.json was put back from an older copy (Time Machine, say), so Sync with iCloud laid out iCloud's version instead."),
                                   symbol: "icloud", duration: 8)
        }
    }

    /// Removals held: the library here as it was before them, from iCloud, with what else changed here kept.
    func bringBackRemovals() {
        session?.bringBackHeld()
        sent()
        changed.send()
    }

    /// Removals held: removed from iCloud and every Mac too.
    func sendRemovals() {
        session?.sendHeld()
        sent()
        changed.send()
    }

    /// What was waiting has gone up (or nothing waits): the line under the switch says so, held removals or not.
    fileprivate func sent() {
        guard let session else { return }
        shown = Self.status(afterSending: shown, merged: session.state.merged, lastSynced: session.state.lastSynced)
    }

    static func status(afterSending shown: Status, merged: Bool, lastSynced: Date?) -> Status {
        merged && shown == .syncing ? .synced(lastSynced) : shown
    }

    /// What sync starts from at launch. A library that couldn't be read (and started afresh) is merged with iCloud as
    /// on a first sync, so iCloud fills it in rather than its missing spaces being removed from every Mac. A first
    /// sync that didn't finish reads all of iCloud again, not only what changed since it was cut short. `account`: the
    /// one sync was turned on with, kept apart too, so a State.json that couldn't be read doesn't let another in.
    static func stateAtLaunch(saved: SyncState, libraryWasRead: Bool, account: String? = nil) -> SyncState {
        var state = saved
        if !libraryWasRead {
            state = SyncState()
            state.account = saved.account
            state.aliases = saved.aliases
        }
        if !state.merged { state.engine = nil }
        if state.account == nil { state.account = account }
        return state
    }

    /// When each carried preference changed while sync was off, by key, so turning it on again counts each from then.
    static let preferenceTimesKey = "SyncWithICloudPreferenceTimes"
    private var preferenceObserver: NSObjectProtocol?
    private var lastPreferences: [String: SettingValue] = [:]
    private let preferenceDebouncer = Debouncer(delay: 1, maxWait: 5)

    private func currentPreferences() -> [String: SettingValue] {
        SyncPreferences.read(from: .standard, profiles: Set(Library.shared.profiles.map(\.id)))
    }

    private func watchPreferencesWhileOff() {
        guard preferenceObserver == nil else { return }
        lastPreferences = currentPreferences()
        preferenceObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceDebouncer.call { self?.notePreferences() } }
        }
    }

    private func notePreferences() {
        let now = currentPreferences()
        defer { lastPreferences = now }
        // While on, sync reads them as they change.
        guard !isOn else { return }
        var times = UserDefaults.standard.dictionary(forKey: Self.preferenceTimesKey) as? [String: Date] ?? [:]
        let changed = Set(now.keys).union(lastPreferences.keys).filter { now[$0] != lastPreferences[$0] }
        guard !changed.isEmpty else { return }
        for key in changed { times[key] = Date() }
        UserDefaults.standard.set(times, forKey: Self.preferenceTimesKey)
    }

    /// The account sync was turned on with, beside State.json.
    static let accountKey = "SyncWithICloudAccount"

    /// Turned on in Settings: a backup first, then the first sync merges this Mac's library with iCloud's. Without the
    /// backup (a full disk), it stays off.
    func turnOn(backingUp: () -> URL? = { ICloudSync.shared.backUp() }) {
        guard !isOn else { return }
        guard backingUp() != nil else { shown = .backupFailed; return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        stop()
        start(state: Self.stateTurningOn(saved: JSONStore.load(SyncState.self, from: Self.stateFile)))
    }

    /// What's kept while sync is off: which items here match which in iCloud, and what this Mac and iCloud last agreed
    /// on, so turning it on again keeps what changed on each side since (`stateTurningOn`). Not after iCloud's copy
    /// was removed (`keepingLibrary` false): then it's merged afresh.
    static func stateTurningOff(_ state: SyncState?, keepingLibrary: Bool = true) -> SyncState {
        var kept = SyncState()
        kept.aliases = state?.aliases ?? SyncAliases()
        // This Mac's ID in a first-sync claim, so a claim it made is still known as its own.
        kept.device = state?.device
        kept.claimSeen = state?.claimSeen
        guard keepingLibrary, let state, state.merged else { return kept }
        kept.merged = true
        // A first sync still going up when it was turned off carries on, and marks its claim complete.
        kept.claimed = state.claimed
        kept.base = state.base
        kept.serverPayloads = state.serverPayloads
        kept.serverDates = state.serverDates
        kept.systemFields = state.systemFields
        kept.unsent = state.unsent
        kept.emptyFolders = state.emptyFolders
        kept.keptProfiles = state.keptProfiles
        kept.libraryStamp = state.libraryStamp
        kept.lastSynced = state.lastSynced
        // Only for the same account: another one is merged afresh.
        kept.resumeAccount = state.account ?? state.resumeAccount
        return kept
    }

    /// Turned on again: what changed only here is kept, what changed only in iCloud is taken, what changed on both
    /// goes to the later (this Mac's edits made while off count from when its library was last saved), and what was
    /// removed here goes as any removal at launch does, many at once held. All of iCloud is read again, so what was
    /// removed there goes too.
    static func stateTurningOn(saved: SyncState?) -> SyncState {
        var state = stateTurningOff(saved)
        state.resumed = state.merged
        return state
    }

    /// Turned off: everything stays on this Mac, and iCloud keeps its copy.
    func turnOff(keepingLibrary: Bool = true) {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        let state = session?.state ?? JSONStore.load(SyncState.self, from: Self.stateFile)
        stop()
        NSApplication.shared.unregisterForRemoteNotifications()
        JSONStore.save(Self.stateTurningOff(state, keepingLibrary: keepingLibrary), to: Self.stateFile)
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        shown = .off
    }

    /// Remove from iCloud…: the synced copy goes from iCloud, for every Mac; this Mac keeps its own, and sync turns off.
    func removeFromICloud() async -> Bool {
        guard Self.isEntitled else { shown = .notEntitled; return false }
        // Stopped first, so nothing makes the zone again on its way out.
        stop()
        let container = CKContainer(identifier: Self.containerID)
        do {
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [Self.zoneID])
        } catch let error as CKError where error.code == .zoneNotFound {
        } catch {
            Self.log.error("removing the zone failed: \(error.localizedDescription, privacy: .public)")
            startIfOn()
            shown = Self.status(for: error) ?? .failed(error.localizedDescription)
            return false
        }
        turnOff(keepingLibrary: false)
        UserDefaults.standard.set(false, forKey: Self.copyKey)
        return true
    }

    private func start(state: SyncState) {
        let session = SyncSession(host: host, state: state)
        session.onChange = { [weak self] in self?.saveSoon() }
        session.onTookICloud = { [weak self] in self?.tellTookICloud() }
        session.onHeld = { [weak self] in
            self?.changed.send()
            if self?.session?.state.heldRemovals != nil { self?.tellHeld() }
        }
        session.onRemovedElsewhere = { [weak self] in self?.zoneDeleted(reset: false) }
        session.onWaiting = { [weak self] in self?.retry.failed(nil) }
        session.onStartedOver = { [weak self] in
            self?.engine?.stop()
            self?.engine = nil
            Task { await self?.connect() }
        }
        session.onNeedsFetch = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.pushDebouncer.call { self?.fetchSoon(after: 0) } }
        }
        self.session = session
        watchLibrary()
        session.checkAfterLaunch()
        UserDefaults.standard.removeObject(forKey: Self.preferenceTimesKey)
        // CKSyncEngine listens for pushes too, but its own fetch on one goes through a scheduler that can refuse it.
        NSApplication.shared.registerForRemoteNotifications()
        shown = .syncing
        Task { await connect() }
    }

    private func stop() {
        saveNow()
        engine?.stop()
        engine = nil
        session?.close()
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
        guard Self.isEntitled else { shown = .notEntitled; return }
        // One engine at a time.
        guard !connecting, engine == nil else { return }
        connecting = true
        defer { connecting = false }
        let container = CKContainer(identifier: Self.containerID)
        do {
            switch try await container.accountStatus() {
            case .available: break
            // Signing in, or iCloud allowed again, posts CKAccountChanged.
            case .noAccount: shown = .notSignedIn; return
            case .restricted: shown = .restricted; return
            default: shown = .offline; retry.failed(nil); return
            }
            let user = try await container.userRecordID().recordName
            guard let session, isOn else { return }
            // What was kept while off belongs to the account it was synced with: another one is merged afresh.
            if let earlier = session.state.resumeAccount {
                if earlier != user { session.startOver() } else { session.updateState { $0.resumeAccount = nil } }
            }
            guard Self.mayUse(account: user, saved: session.state.account) else { shown = .otherAccount; return }
            session.updateState { $0.account = user }
            UserDefaults.standard.set(user, forKey: Self.accountKey)
            let engine = CloudEngine(container: container, session: session, owner: self)
            self.engine = engine
            session.server = engine
            engine.start()
            // What's unsent is queued again by the catch-up, after its fetch has read what was removed meanwhile.
            await catchUp()
        } catch {
            Self.log.error("connecting failed: \(error.localizedDescription, privacy: .public)")
            failed(error)
        }
    }

    /// Every connection and every fetch: the first sync's merge, or what changed elsewhere while this Mac was away;
    /// then what's waiting here goes up.
    private var catchingUp = false, catchUpAgain = false

    /// One at a time: one asked for meanwhile runs once more after it.
    private func catchUp() async {
        guard !catchingUp else { catchUpAgain = true; return }
        catchingUp = true
        defer { catchingUp = false }
        repeat {
            catchUpAgain = false
            await catchUpOnce()
        } while catchUpAgain
    }

    private func catchUpOnce() async {
        guard let engine, let session else { return }
        lastFetch = Date()
        do {
            try await Self.catchUp(session, through: engine, isCurrent: { [weak self] in self?.session === session }) { [weak self] first in
                guard let self else { return }
                if first {
                    UserDefaults.standard.set(true, forKey: Self.copyKey)
                    shown = .synced(session.state.lastSynced)
                }
                if session.state.resumed { session.updateState { $0.resumed = false } }
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
        if !session.state.merged {
            // This Mac's claim on an empty iCloud goes up first; once it's saved, the library follows.
            session.requeue()
            try await server.sendChanges()
            // Not merged still: another Mac's first sync is going up, and this one reads again later.
            guard session.state.merged else { return }
        }
        fetched(first)
        session.requeue()
        try await server.sendChanges()
        // The first sync's library has all gone up: its claim, marked complete, goes too.
        if session.state.unsent.contains(SyncName.claim) { try await server.sendChanges() }
    }

    /// The status for a failure, and the next try unless waiting won't help.
    private func failed(_ error: Error) {
        shown = Self.status(for: error) ?? (SyncRetry.isPermanent(error) ? .failed(error.localizedDescription) : .offline)
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
                MainActor.assumeIsolated { self?.woke() }
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

    /// What failed is tried again, and otherwise what changed while the Mac slept is fetched.
    private func woke() {
        if retry.failures > 0 || retry.isStopped { retry.soon() } else { fetchSoon(after: 60) }
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

    /// A push from iCloud: another Mac changed something, so the zone is fetched.
    func remoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard isOn, session != nil, Self.isOurPush(userInfo) else { return }
        pushDebouncer.call { [weak self] in self?.fetchSoon(after: 0) }
    }

    static func isOurPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.containerIdentifier == containerID
    }

    // MARK: Saving the state

    private func saveSoon() { saveDebouncer.call { [weak self] in self?.writeState() } }

    /// Before quitting, and when sync stops: Library.json first, then what changed in it read now, not at the next
    /// launch, then sync's own state.
    func saveNow() {
        Library.shared.saveNow()
        localDebouncer.cancel()
        session?.localChanged()
        writeState()
    }

    private func writeState() {
        saveDebouncer.cancel()
        guard let session else { return }
        var state = session.state
        if let engine { state.engine = engine.serialization ?? state.engine }
        JSONStore.save(state, to: Self.stateFile)
    }

    // MARK: Before the first sync

    /// A Zigzag backup of what's here now, in Backups, with every preference sync carries. Restoring it (File › Import)
    /// adds back what's missing; it doesn't undo renames or remove what the merge added.
    @discardableResult
    func backUp() -> URL? {
        let folder = Paths.directory("Backups")
        guard let data = try? ZigzagBackup.make(managers: [], openTabs: false, history: false).encoded() else { return nil }
        let url = DataExport.unusedFile(named: DataExport.backupName(), in: folder)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    // MARK: From the engine

    fileprivate func engineEvent(_ status: Status) { shown = status }

    /// iCloud is full: changes wait here, tried again with the usual waits.
    fileprivate func iCloudFull() {
        shown = .full
        retry.failed(CKError(.quotaExceeded))
    }

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
        guard let session, session.state.merged else { return }
        // Gone while sync was off here: merged afresh, as sync was just turned on.
        if session.state.resumed { zoneDeleted(reset: true); return }
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
            turnOff(keepingLibrary: false)
            UserDefaults.standard.set(false, forKey: Self.copyKey)
            shown = .removedElsewhere
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

    /// Waiting won't fix these: they show their status and wait for the account, the network or a wake. A full iCloud
    /// isn't one: room is made without a sign, so it's tried again on the usual schedule.
    static func isPermanent(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .notAuthenticated, .managedAccountRestricted, .incompatibleVersion, .badContainer,
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

    var libraryStamp: Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.library.path))?[.modificationDate] as? Date
    }

    var settingTimes: [String: Date] { UserDefaults.standard.dictionary(forKey: ICloudSync.preferenceTimesKey) as? [String: Date] ?? [:] }

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
    /// When the engine's current fetch started.
    private var fetchStarted: Date?
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
        // Made only by the first sync: a zone gone after it was removed elsewhere, and isn't made again.
        if session?.state.merged != true { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ICloudSync.zoneID))]) }
    }

    func stop() {
        engine = nil
    }

    func fetchChanges(_ scope: SyncFetchScope) async throws {
        switch scope {
        case .pending: try await engine?.fetchChanges()
        // Without a push the engine knows of no changed zone and asks nothing, so the zone is named.
        case .zone:
            try await engine?.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([ICloudSync.zoneID])))
            try await fetchZone()
        }
    }

    /// The zone's changes since Zigzag's own token, read without CKSyncEngine, which only fetches a zone a push marked.
    /// Each batch is saved with the token it brought; once merged, what came settles into the library.
    private func fetchZone() async throws {
        guard let session else { return }
        let started = session.now()
        let database = container.privateCloudDatabase
        var token = session.state.zoneToken.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        // Read from the start: what isn't there any more was removed.
        var all: Set<String>? = token == nil ? [] : nil
        var more = true
        while more {
            let changes: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                          deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                changes = try await database.recordZoneChanges(inZoneWith: ICloudSync.zoneID, since: token)
            } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
                // Read from the start again: what's already here takes no change.
                token = nil
                all = []
                continue
            }
            guard self.session === session else { return }
            let records = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                .filter { $0.recordID.zoneID == ICloudSync.zoneID }.map(Self.remote)
            session.fetched(records, deleted: changes.deletions.map(\.recordID.recordName), startedAt: started)
            all?.formUnion(records.map(\.name))
            token = changes.changeToken
            let archived = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true)
            session.updateState { $0.zoneToken = archived }
            more = changes.moreComing
        }
        if let all { session.readAll(all) }
        if session.state.merged { session.fetchFinished() }
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
                          systemFields: coder.encodedData, serverModified: record.modificationDate)
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
            session.fetched(records, deleted: changes.deletions.filter { $0.recordID.zoneID == ICloudSync.zoneID }.map(\.recordID.recordName),
                            startedAt: fetchStarted)
        case .sentRecordZoneChanges(let sent):
            session.saved(sent.savedRecords.map(Self.remote))
            session.deleted(sent.deletedRecordIDs.map(\.recordName))
            var full = false
            defer { if full { owner?.iCloudFull() } }
            for failure in sent.failedRecordSaves {
                let name = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    if let server = failure.error.serverRecord { session.saveFailed(name, .conflict(Self.remote(server))) } else { session.saveFailed(name, .conflictUnread) }
                case .zoneNotFound, .userDeletedZone:
                    if !session.state.merged { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: ICloudSync.zoneID))]) }
                    session.saveFailed(name, .zoneMissing)
                    if session.state.merged { return }
                case .unknownItem:
                    session.saveFailed(name, .gone)
                case .quotaExceeded:
                    // Stays unsent and goes up again after a wait.
                    full = true
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
                    break
                default:
                    Self.log.error("a save failed: \(failure.error.localizedDescription, privacy: .public)")
                    owner?.engineEvent(.failed(failure.error.localizedDescription))
                }
            }
            for (id, error) in sent.failedRecordDeletes {
                switch error.code {
                case .unknownItem:
                    session.deleteFailed(id.recordName, .gone)
                case .zoneNotFound, .userDeletedZone:
                    session.deleteFailed(id.recordName, .zoneMissing)
                    if session.state.merged { return }
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
                    // The engine tries these again itself.
                    break
                default:
                    // Asked again with the next sync, from the state.
                    Self.log.error("a removal failed: \(error.localizedDescription, privacy: .public)")
                    owner?.engineEvent(.failed(error.localizedDescription))
                }
            }
        case .willFetchChanges:
            fetchStarted = session.now()
            owner?.engineEvent(.syncing)
        case .willSendChanges:
            owner?.engineEvent(.syncing)
        case .didFetchChanges:
            fetchStarted = nil
            guard session.state.merged else { break }
            session.fetchFinished()
            owner?.retry.succeeded()
            owner?.engineEvent(.synced(session.state.lastSynced))
        case .didSendChanges:
            owner?.sent()
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }.sorted { a, b in
            func key(_ change: CKSyncEngine.PendingRecordZoneChange) -> (Int, Int, String) {
                switch change {
                case .saveRecord(let id): (0, SyncName.rank(id.recordName), id.recordName)
                // A profile's removal first, so another Mac knows it before its spaces move off it.
                case .deleteRecord(let id): (SyncName.rank(id.recordName) == 0 ? -1 : 1, SyncName.rank(id.recordName), id.recordName)
                @unknown default: (2, 0, "")
                }
            }
            return key(a) < key(b)
        }
        guard !pending.isEmpty else { return nil }
        // While this Mac's first sync goes up, the renewed claim goes alone before each part.
        if let claim = pending.first, case .saveRecord(let id) = claim, id.recordName == SyncName.claim, session?.claimFirst == true {
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: [claim]) { [weak self] id in await self?.record(for: id) }
        }
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

import AppKit
import Sparkle

/// Automatic updates via Sparkle, which downloads, checks each update's signature and installs it. Zigzag looks every
/// few hours and on waking from sleep, quietly; once an update is ready the sidebar says so, with a Restart that
/// brings everything back in the new version, and an update you don't restart for installs when Zigzag quits.
///
/// Sparkle never shows a window of its own: `QuietUserDriver` stands in for its standard one, so an update found in
/// the background stays out of the way, and Check for Updates… answers in a toast.
final class Updater {
    static let shared = Updater()
    private var updater: SPUUpdater?
    private let delegate = UpdaterDelegate()
    private let driver = QuietUserDriver()

    /// Betas come from their own feed, which also carries every stable release, so turning betas off later never
    /// strands you: the next stable version newer than your beta comes through either feed.
    static let betaFeed = "https://zigzagbrowser.com/updates/beta.xml"
    private static let betaKey = "BetaUpdates"

    /// Get new versions before everyone else, to try them on your own tabs and data. Running a beta means you
    /// chose to, so it's on until you turn it off.
    static var getsBetas: Bool {
        get { UserDefaults.standard.object(forKey: betaKey) as? Bool ?? isBeta }
        set {
            UserDefaults.standard.set(newValue, forKey: betaKey)
            // Look again at once, on the feed just chosen.
            if newValue, let updater = shared.updater, !updater.sessionInProgress { updater.checkForUpdatesInBackground() }
        }
    }

    /// This copy of Zigzag is a beta (0.5.0-beta.1).
    static var isBeta: Bool { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").contains("-beta") }

    /// Only signed release builds with a feed key can update; debug builds stay put.
    private var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty
    }

    /// The update that's ready, if one is: the sidebar's card, the Zigzag menu and Settings follow it (`changed`).
    private(set) var readiness = UpdateReadiness() {
        didSet { if readiness != oldValue { Self.changed.send() } }
    }
    static let changed = Signal<Void>()

    /// Zigzag › Check for Updates…, or Restart to Update while one is ready.
    var menuTitle: String {
        readiness.canRestart ? String(localized: "Restart to Update", comment: "Zigzag menu item in place of Check for Updates… while an update is ready: restarts Zigzag into it.")
            : String(localized: "Check for Updates…", comment: "Zigzag menu item.")
    }

    /// Restart asked for: `waiting` while Sparkle finishes something else, `running` once it's installing.
    private enum Restart { case none, waiting, running }
    private var restart = Restart.none
    /// Check for Updates… is under way: it answers in toasts, where a quiet check says nothing.
    private var manualCheck = false
    /// The window whose toast says "Checking…" or "Downloading…", put away when the check ends without a word.
    private weak var workingToast: BrowserWindowController?
    /// The staged update was let go for a newer one: Sparkle fetches that as soon as it's done.
    private var fetchesAfterCycle = false
    /// What Sparkle last said it found, staged once it's ready.
    private var found: UpdateReadiness.Staged?
    private var clock: Timer?
    private var wakeObserver: NSObjectProtocol?
    #if DEBUG
    /// Shown by the debug command `updateready`: Restart only says what it would do.
    private var stagedForDebug = false
    #endif

    func start() {
        // The first run of a beta keeps you on betas from then on, even after a stable version replaces it.
        if Self.isBeta, UserDefaults.standard.object(forKey: Self.betaKey) == nil { UserDefaults.standard.set(true, forKey: Self.betaKey) }
        guard isConfigured else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        guard (try? updater.start()) != nil else { return }
        self.updater = updater
        // Sparkle looks every few hours by itself (SUScheduledCheckInterval), but stops once an update is staged:
        // this clock goes on, so the staged update is compared with the feed and a newer one takes its place.
        let clock = Timer(timeInterval: 30 * 60, repeats: true) { _ in MainActor.assumeIsolated { Updater.shared.checkQuietly(onWake: false) } }
        clock.tolerance = 5 * 60
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        // A Mac that sleeps most of the day still hears of updates: after a wake, once the network is back.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { Updater.shared.checkQuietly(onWake: true) } }
        }
    }

    /// A look for something new, with nothing shown: Sparkle downloads what it finds and stages it, or, with an update
    /// already staged, Zigzag compares that one with the feed (`found(_:state:reply:)`).
    func checkQuietly(onWake: Bool) {
        guard let updater, !updater.sessionInProgress, restart == .none,
              UpdateSchedule.shouldCheck(lastCheck: updater.lastUpdateCheckDate, now: Date(), onWake: onWake) else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Zigzag › Check for Updates… and Settings' button: with an update ready, restarts into it; otherwise looks now
    /// and says what it found in a toast.
    func checkForUpdates() {
        if readiness.canRestart { restartToUpdate(); return }
        guard let updater else {
            // A development build: say so where you're looking, not in a system alert.
            say(String(localized: "This build doesn’t update itself. Release builds of Zigzag update automatically.",
                       comment: "Toast after Check for Updates in a development build."), symbol: "arrow.down.circle")
            return
        }
        let checking = String(localized: "Checking for updates…", comment: "Toast while Zigzag › Check for Updates… looks for a new version.")
        // Asked again while the first is under way: the same check goes on.
        if manualCheck { sayWorking(checking); return }
        manualCheck = true
        sayWorking(checking)
        whenSparkleIsFree { [weak self] in
            guard let self, self.manualCheck else { return }
            // A quiet check that was under way may have staged one meanwhile.
            if self.readiness.canRestart { self.sayReady(); self.manualCheck = false; return }
            // Sparkle still busy after the wait, or not taking checks: it would start nothing, and no answer would
            // ever come, so say so now.
            guard updater.canCheckForUpdates else { self.failed(); self.manualCheck = false; return }
            updater.checkForUpdates()
        }
    }

    /// The card's Restart, Zigzag › Restart to Update and Settings': Sparkle installs the staged update and opens
    /// Zigzag again, with every window and tab as it was (`UpdateRelaunch`, written as Sparkle asks to relaunch).
    func restartToUpdate() {
        #if DEBUG
        if stagedForDebug {
            say(String(localized: "Zigzag would restart into \(VersionName.display(readiness.staged?.version ?? "")) now.",
                       comment: "Debug builds only: toast after Restart on a pretend update. The placeholder is its version."), symbol: "arrow.clockwise")
            return
        }
        #endif
        guard let updater, readiness.canRestart, restart == .none else { return }
        restart = .waiting
        whenSparkleIsFree { [weak self] in
            guard let self, self.restart == .waiting else { return }
            // Sparkle would start nothing, and the restart would wait for good, holding up every later check.
            guard updater.canCheckForUpdates else { self.failed(); self.restart = .none; return }
            self.restart = .running
            // The staged update is resumed, as a check you asked for, and installed at once (`found`).
            updater.checkForUpdates()
        }
    }

    /// The card's ×: away for this version until Zigzag restarts. The update still installs when Zigzag quits.
    func dismissCard() { readiness.dismiss() }

    /// Runs `action` once Sparkle has no check of its own under way.
    private func whenSparkleIsFree(_ action: @escaping () -> Void, tries: Int = 120) {
        guard let updater else { return }
        guard updater.sessionInProgress, tries > 0 else { action(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.whenSparkleIsFree(action, tries: tries - 1) }
        }
    }

    // MARK: What Sparkle says

    /// Sparkle found an update. One already staged (`installing`) is installed now for Restart; found by a quiet check,
    /// it's compared with the feed, and let go when there's a newer one. Anything else is downloaded, in the
    /// background unless you asked.
    fileprivate func found(_ item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let update = UpdateReadiness.Staged(version: item.displayVersionString, build: item.versionString)
        found = update
        if item.isInformationOnlyUpdate { reply(.dismiss); return }
        guard state.stage == .installing else {
            // Asked for, or Restart found its staged update gone and fetches it again.
            if manualCheck || restart == .running {
                sayWorking(String(localized: "Downloading Zigzag \(VersionName.display(update.version))…", comment: "Toast while Check for Updates… downloads a new version. The placeholder is the version."))
            }
            reply(.install)
            return
        }
        if restart == .running { reply(.install); return }
        if state.userInitiated { stage(update); reply(.dismiss); return }
        newestOnFeed { [weak self] newest in
            guard let self else { return }
            if let newest, UpdateReadiness.isNewer(newest.build, than: update.build) {
                // Out of date: Sparkle lets it go, and once it's done, downloads the newer one in its place.
                self.readiness.clear()
                self.fetchesAfterCycle = true
                reply(.skip)
            } else {
                self.stage(update)
                reply(.dismiss)
            }
        }
    }

    /// Downloaded, checked and ready to install: staged until Restart, or until Zigzag quits.
    fileprivate func readyToInstall(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if let found { stage(found) }
        reply(restart == .running ? .install : .dismiss)
    }

    /// The same, from Sparkle's automatic downloads. Restart asked for meanwhile installs it at once.
    fileprivate func willInstallOnQuit(_ item: SUAppcastItem, now install: @escaping () -> Void) -> Bool {
        stage(.init(version: item.displayVersionString, build: item.versionString))
        guard restart != .none else { return false }
        restart = .running
        install()
        return true
    }

    /// No newer version: nothing staged after all (its installer went), so nothing to restart for. Sparkle tells
    /// both the user driver (`manual`) and the delegate; the toast is said once.
    fileprivate func noUpdate(manual: Bool) {
        readiness.clear()
        if manual {
            say(String(localized: "Zigzag is up to date.", comment: "Toast after Check for Updates… finds no newer version."), symbol: "checkmark.circle")
        }
    }

    fileprivate func failed() {
        guard manualCheck || restart != .none else { return }
        say(String(localized: "Couldn’t check for updates. Try again later.", comment: "Toast when Check for Updates… or Restart to Update can't reach the update feed."),
            symbol: "exclamationmark.triangle")
    }

    fileprivate func cycleFinished() {
        // A restart that's running and still here didn't happen; one waiting for this check to end goes on.
        if restart == .running { restart = .none }
        workingTimeout?.cancel()
        if let window = workingToast { Toast.hide(in: window) }
        manualCheck = false
        workingToast = nil
        if fetchesAfterCycle {
            fetchesAfterCycle = false
            whenSparkleIsFree { [weak self] in self?.updater?.checkForUpdatesInBackground() }
        }
    }

    private func stage(_ update: UpdateReadiness.Staged) {
        readiness.stage(version: update.version, build: update.build)
        if manualCheck { sayReady() }
    }

    /// One session for every look at the feed, with no cookies or cache kept: a session made per look is never
    /// let go of.
    private static let feedSession = URLSession.cookieless

    /// The newest version on the feed Sparkle reads, or nil when it can't be read.
    private func newestOnFeed(_ done: @escaping (UpdateFeed.Item?) -> Void) {
        guard let url = updater?.feedURL else { done(nil); return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        Task {
            let answer = try? await Self.feedSession.data(for: request)
            let ok = (answer?.1 as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            done(ok ? answer.flatMap { UpdateFeed.newest(in: $0.0) } : nil)
        }
    }

    // MARK: Toasts

    private var toastWindow: BrowserWindowController? { WindowManager.shared.keyController ?? WindowManager.shared.controllers.first }

    private func say(_ text: String, symbol: String, action: (title: String, run: () -> Void)? = nil) {
        guard let window = toastWindow else { return }
        workingToast = nil
        workingTimeout?.cancel()
        Toast.show(text, symbol: symbol, action: action, duration: action == nil ? 3 : 6, in: window)
    }

    /// How long "Checking…" or "Downloading…" stays up when no word comes from Sparkle: then it goes, and the check
    /// is no longer one you asked for (what it finds still shows in the sidebar).
    static let workingLimit: TimeInterval = 90
    private var workingTimeout: DispatchWorkItem?

    private func sayWorking(_ text: String) {
        workingTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let window = self.workingToast { Toast.hide(in: window) }
                self.workingToast = nil
                self.manualCheck = false
            }
        }
        workingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.workingLimit, execute: timeout)
        guard let window = toastWindow else { return }
        workingToast = window
        Toast.working(text, in: window)
    }

    private func sayReady() {
        guard let version = readiness.staged.map({ VersionName.display($0.version) }) else { return }
        say(String(localized: "Zigzag \(version) is ready.", comment: "Toast after Check for Updates… has downloaded a new version. The placeholder is the version."),
            symbol: "arrow.clockwise.circle",
            action: (String(localized: "Restart", comment: "Button that restarts Zigzag into an update that's ready: on the sidebar's update card, in a toast and in Settings › General."),
                     { Updater.shared.restartToUpdate() }))
    }

    #if DEBUG
    /// `updateready <version>`: the card, menu item and Settings row for a pretend update; `off` takes it away.
    func debugStage(_ version: String?) {
        stagedForDebug = version != nil
        var shown = UpdateReadiness()
        if let version { shown.stage(version: version, build: version) }
        readiness = shown
    }
    #endif
}

/// Sparkle's questions, answered for Zigzag: which feed, the release notes it never shows, and what's staged.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Updater.getsBetas ? Updater.betaFeed : nil
    }

    /// Zigzag shows what's new itself, after the update.
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Updater.shared.willInstallOnQuit(item, now: immediateInstallHandler)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Updater.shared.noUpdate(manual: false)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Updater.shared.cycleFinished()
    }

    /// Restarting to finish an update isn't a quit to ask about, and everything open comes back after it: the
    /// windows, tabs and Zigzag Mini windows are written down before Sparkle quits Zigzag.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { UpdateRelaunch.prepare() }
    }
}

/// Sparkle's user interface, as Zigzag's: nothing pops up. What a check finds goes to `Updater`, which stages it
/// for the sidebar's card; a check you asked for answers in a toast.
private final class QuietUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on, so Sparkle doesn't ask; if it ever does, the answer is the same.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Updater.shared.found(appcastItem, state: state, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Updater.shared.noUpdate(manual: true)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Updater.shared.failed()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Updater.shared.readyToInstall(reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}
    func dismissUpdateInstallation() {}
}

/// Copies of your data from before each update: spaces, pins, favorites, open tabs and history. The last three
/// are kept. Logins, cookies and passwords live with macOS and WebKit, outside any update's reach, so they're not
/// part of it.
nonisolated enum UpdateBackup {
    private static let files = ["Library.json", "Profiles.json", "Session.json", "Downloads.json", "History.sqlite", "History.sqlite-wal", "History.sqlite-shm"]
    /// Left as it is when a backup from before there were profiles is put back: without it every space would land
    /// on the first profile, away from the sign-ins and extensions it had.
    private static let keptWhenNotInBackup: Set<String> = ["Profiles.json"]
    private static let historyFiles = ["History.sqlite", "History.sqlite-wal", "History.sqlite-shm"]
    private static let kept = 3

    /// The histories of the profiles made since the first, as paths under `root` (the data folder, or a backup of
    /// it): each is kept in its profile's folder.
    private static func profileFiles(in root: URL) -> [String] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Profiles", isDirectory: true).path)) ?? []
        return ids.filter { UUID(uuidString: $0) != nil }.sorted().flatMap { id in historyFiles.map { "Profiles/\(id)/\($0)" } }
    }

    /// A removed profile goes from every backup too: its history, and its name in the backup's own lists, with
    /// the favorites that were its. Putting a backup back then never brings back an emptied profile, or what the
    /// removal said was gone for good; the spaces it had come back on the first profile, as they are now.
    static func forget(profile: UUID, in root: URL = Paths.support) {
        let id = profile.uuidString
        func edit(_ file: URL, _ change: (inout [String: Any]) -> Void) {
            guard let data = try? Data(contentsOf: file), var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            change(&json)
            if let data = try? JSONSerialization.data(withJSONObject: json) { try? data.write(to: file, options: .atomic) }
        }
        for backup in all(in: root) {
            try? FileManager.default.removeItem(at: backup.appendingPathComponent("Profiles/\(id)", isDirectory: true))
            var favorites: Set<String> = []
            edit(backup.appendingPathComponent("Profiles.json")) { json in
                let owned = (json["favorites"] as? [String: String]) ?? [:]
                favorites = Set(owned.filter { $0.value == id }.keys)
                if json["favorites"] != nil { json["favorites"] = owned.filter { $0.value != id } }
                if let spaces = json["spaces"] as? [String: String] { json["spaces"] = spaces.filter { $0.value != id } }
                for list in ["others", "deleting"] {
                    if let profiles = json[list] as? [[String: Any]] { json[list] = profiles.filter { $0["id"] as? String != id } }
                }
            }
            guard !favorites.isEmpty else { continue }
            edit(backup.appendingPathComponent("Library.json")) { json in
                if let kept = json["favorites"] as? [[String: Any]] { json["favorites"] = kept.filter { !favorites.contains($0["id"] as? String ?? "") } }
                if let splits = json["favoriteSplits"] as? [[String: Any]] {
                    json["favoriteSplits"] = splits.filter { !favorites.contains($0["left"] as? String ?? "") && !favorites.contains($0["right"] as? String ?? "") }
                }
            }
        }
    }
    private static let restoreMarker = "Restore"
    private static let lastBuildKey = "LastRunBuild"
    private static let lastVersionKey = "LastRunVersion"
    /// Ends the name of a backup made just before a restore, so a restore that wasn't wanted can be undone.
    private static let beforeRestore = "before restore"

    private static func folder(in root: URL) -> URL { root.appendingPathComponent("Backups", isDirectory: true) }

    /// The backups, newest first.
    static func all(in root: URL = Paths.support) -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder(in: root), includingPropertiesForKeys: nil)) ?? []
        return found.filter(\.hasDirectoryPath).sorted {
            (date(of: $0.lastPathComponent) ?? .distantPast) > (date(of: $1.lastPathComponent) ?? .distantPast)
        }
    }

    /// The backups made at updates, newest first: the ones a restore puts back.
    static func updates(in root: URL = Paths.support) -> [URL] {
        all(in: root).filter { !$0.lastPathComponent.hasSuffix(beforeRestore) }
    }

    /// The backup a restore puts back: the newest that holds your spaces. One without them (made over a data folder
    /// that had nothing yet) has nothing to give back, so it's never offered.
    static func restorable(in root: URL = Paths.support) -> URL? {
        updates(in: root).first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Library.json").path) }
    }

    static var latest: URL? { restorable() }

    /// When the newest backup was made, from its name.
    static var latestDate: Date? {
        latest.flatMap { date(of: $0.lastPathComponent) }
    }

    /// When a backup was made, from its name: in UTC, so a change of time zone or clocks can't reorder them.
    /// Older backups were named in local time, without the Z.
    static func date(of name: String) -> Date? {
        stamp.date(from: String(name.prefix(20))) ?? localStamp.date(from: String(name.prefix(19)))
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()

    private static let localStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    /// At launch, before anything reads your data: the first run of a new build backs up what the last one left,
    /// named for the version it came from. Sparkle installs most updates quietly on quit, so this is the one moment
    /// every update passes through.
    static func backUpIfUpdated(build: String, version: String, defaults: UserDefaults = .standard, root: URL = Paths.support) {
        let lastBuild = defaults.string(forKey: lastBuildKey)
        guard lastBuild != build else { return }
        // Only what an earlier run left: a first run has no data yet, whatever build last ran (a fresh data folder,
        // or Zigzag installed again after its data was removed), and a backup of nothing would be offered as one.
        // A run from before builds were recorded is backed up all the same.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Library.json").path) {
            make(from: defaults.string(forKey: lastVersionKey), in: root)
        }
        defaults.set(build, forKey: lastBuildKey)
        defaults.set(version, forKey: lastVersionKey)
    }

    /// Named for when it was made and the version it was made from, when that's known. Whole or not at all: a
    /// file that can't be copied leaves no backup. The last three of each kind are kept.
    @discardableResult
    static func make(from version: String?, beforeRestoring: Bool = false, in root: URL = Paths.support) -> URL? {
        let name = [stamp.string(from: Date()), version, beforeRestoring ? beforeRestore : nil].compactMap { $0 }.joined(separator: " ")
        let target = folder(in: root).appendingPathComponent(name, isDirectory: true)
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: target, withIntermediateDirectories: true)) != nil else { return nil }
        for name in files + profileFiles(in: root) {
            let source = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            let copy = target.appendingPathComponent(name)
            try? manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? manager.copyItem(at: source, to: copy)) != nil else {
                try? manager.removeItem(at: target)
                return nil
            }
        }
        let sameKind = all(in: root).filter { $0.lastPathComponent.hasSuffix(beforeRestore) == beforeRestoring }
        for old in sameKind.dropFirst(kept) { try? manager.removeItem(at: old) }
        return target
    }

    /// Puts the newest backup back the next time Zigzag starts, before anything reads your data, then restarts
    /// Zigzag so that's now.
    @MainActor static func restoreLatestAndRelaunch() {
        guard let latest else { return }
        try? latest.lastPathComponent.write(to: folder(in: Paths.support).appendingPathComponent(restoreMarker), atomically: true, encoding: .utf8)
        relaunch()
    }

    /// Quits and opens Zigzag again, as when a restore or a new language needs a fresh start.
    @MainActor static func relaunch() {
        let app = Bundle.main.bundleURL
        AppDelegate.quitConfirmed = true
        // The new copy waits for this one to finish saving before it starts reading.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path and process go in as arguments, never into the script itself.
        task.arguments = ["-c", "while kill -0 \"$2\" 2>/dev/null; do sleep 0.2; done; open \"$1\"",
                          "sh", app.path, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// A backup folder's own name, as `make` writes it ("2026-10-02T09-00-00Z 0.4.0"): one path component, dated.
    static func isBackupName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !name.hasPrefix(".")
            && date(of: name) != nil
    }

    /// At launch: if a restore was asked for, the backup's files replace the ones in use. What's there now is
    /// backed up first, and nothing live goes until its replacement is in place.
    static func restoreIfAsked(root: URL = Paths.support) {
        let manager = FileManager.default
        let marker = folder(in: root).appendingPathComponent(restoreMarker)
        guard let name = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? manager.removeItem(at: marker)
        // Only the name of a backup made at an update, right in the Backups folder: never a path out of it.
        guard isBackupName(name) else { return }
        let source = folder(in: root).appendingPathComponent(name, isDirectory: true)
        guard manager.fileExists(atPath: source.path) else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard make(from: version, beforeRestoring: true, in: root) != nil else { return }
        // Each file is copied in beside the one it replaces, then swapped in whole.
        var staged: [(temp: URL, target: URL)] = []
        for file in files + profileFiles(in: source) where manager.fileExists(atPath: source.appendingPathComponent(file).path) {
            let place = root.appendingPathComponent(file)
            let temp = place.deletingLastPathComponent().appendingPathComponent(".\(place.lastPathComponent).restoring")
            try? manager.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: temp)
            guard (try? manager.copyItem(at: source.appendingPathComponent(file), to: temp)) != nil else {
                for item in staged { try? manager.removeItem(at: item.temp) }
                return
            }
            staged.append((temp, place))
        }
        var replacedAll = true
        for item in staged {
            let replaced = manager.fileExists(atPath: item.target.path)
                ? (try? manager.replaceItemAt(item.target, withItemAt: item.temp)) != nil
                : (try? manager.moveItem(at: item.temp, to: item.target)) != nil
            if !replaced { replacedAll = false; try? manager.removeItem(at: item.temp) }
        }
        // A file the backup doesn't have (the history's journal, say) wouldn't match what came back, so it goes,
        // once everything else is in place.
        guard replacedAll else { return }
        for file in files where !keptWhenNotInBackup.contains(file) && !manager.fileExists(atPath: source.appendingPathComponent(file).path) {
            try? manager.removeItem(at: root.appendingPathComponent(file))
        }
        // The other profiles' histories too, when the backup knows of profiles; one from before them leaves the
        // profiles as they are, history and all.
        guard manager.fileExists(atPath: source.appendingPathComponent("Profiles.json").path) else { return }
        for file in profileFiles(in: root) where !manager.fileExists(atPath: source.appendingPathComponent(file).path) {
            try? manager.removeItem(at: root.appendingPathComponent(file))
        }
    }
}

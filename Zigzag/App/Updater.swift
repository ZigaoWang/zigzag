import AppKit
import Sparkle

/// Automatic updates via Sparkle. Checks daily and installs quietly on quit; no prompts unless you ask.
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private let delegate = UpdaterDelegate()

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
            if newValue { shared.controller?.updater.checkForUpdatesInBackground() }
        }
    }

    /// This copy of Zigzag is a beta (0.5.0-beta.1).
    static var isBeta: Bool { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").contains("-beta") }

    /// Only signed release builds with a feed key can update; debug builds stay put.
    private var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty
    }

    func start() {
        // The first run of a beta keeps you on betas from then on, even after a stable version replaces it.
        if Self.isBeta, UserDefaults.standard.object(forKey: Self.betaKey) == nil { UserDefaults.standard.set(true, forKey: Self.betaKey) }
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
        } else {
            // A development build: say so where you're looking, not in a system alert.
            if let window = WindowManager.shared.keyController {
                Toast.show("This build doesn’t update itself. Release builds of Zigzag update automatically", symbol: "arrow.down.circle", duration: 3, in: window)
            }
        }
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Updater.getsBetas ? Updater.betaFeed : nil
    }

    /// Restarting to finish an update isn't a quit to ask about.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { AppDelegate.quitConfirmed = true }
    }
}

/// Copies of your profile from before each update: spaces, pins, favorites, open tabs and history. The last three
/// are kept. Logins, cookies and passwords live with macOS and WebKit, outside any update's reach, so they're not
/// part of it.
nonisolated enum ProfileBackup {
    private static let files = ["Library.json", "Session.json", "Downloads.json", "History.sqlite", "History.sqlite-wal", "History.sqlite-shm"]
    private static let kept = 3
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

    static var latest: URL? { updates().first }

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

    /// At launch, before anything reads the profile: the first run of a new build backs up what the last one left,
    /// named for the version it came from. Sparkle installs most updates quietly on quit, so this is the one moment
    /// every update passes through.
    static func backUpIfUpdated(build: String, version: String, defaults: UserDefaults = .standard, root: URL = Paths.support) {
        let lastBuild = defaults.string(forKey: lastBuildKey)
        guard lastBuild != build else { return }
        // A first run has no profile yet; one from before builds were recorded is backed up all the same.
        if lastBuild != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent("Library.json").path) {
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
        for name in files {
            let source = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else { continue }
            guard (try? manager.copyItem(at: source, to: target.appendingPathComponent(name))) != nil else {
                try? manager.removeItem(at: target)
                return nil
            }
        }
        let sameKind = all(in: root).filter { $0.lastPathComponent.hasSuffix(beforeRestore) == beforeRestoring }
        for old in sameKind.dropFirst(kept) { try? manager.removeItem(at: old) }
        return target
    }

    /// Puts the newest backup back the next time Zigzag starts, before anything reads the profile, then restarts
    /// Zigzag so that's now.
    @MainActor static func restoreLatestAndRelaunch() {
        guard let latest else { return }
        try? latest.lastPathComponent.write(to: folder(in: Paths.support).appendingPathComponent(restoreMarker), atomically: true, encoding: .utf8)
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

    /// At launch: if a restore was asked for, the backup's files replace the profile's. What's there now is
    /// backed up first, and nothing live goes until its replacement is in place.
    static func restoreIfAsked(root: URL = Paths.support) {
        let manager = FileManager.default
        let marker = folder(in: root).appendingPathComponent(restoreMarker)
        guard let name = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? manager.removeItem(at: marker)
        let source = folder(in: root).appendingPathComponent(name, isDirectory: true)
        guard manager.fileExists(atPath: source.path) else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard make(from: version, beforeRestoring: true, in: root) != nil else { return }
        // Each file is copied in beside the one it replaces, then swapped in whole.
        var staged: [(temp: URL, target: URL)] = []
        for file in files where manager.fileExists(atPath: source.appendingPathComponent(file).path) {
            let temp = root.appendingPathComponent(".\(file).restoring")
            try? manager.removeItem(at: temp)
            guard (try? manager.copyItem(at: source.appendingPathComponent(file), to: temp)) != nil else {
                for item in staged { try? manager.removeItem(at: item.temp) }
                return
            }
            staged.append((temp, root.appendingPathComponent(file)))
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
        for file in files where !manager.fileExists(atPath: source.appendingPathComponent(file).path) {
            try? manager.removeItem(at: root.appendingPathComponent(file))
        }
    }
}

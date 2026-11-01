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
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
        } else {
            // A development build: say so where you're looking, not in a system alert.
            if let window = WindowManager.shared.keyController {
                Toast.show("This build doesn’t update itself. Release builds of Zigzag update automatically.", symbol: "arrow.down.circle", duration: 3, in: window)
            }
        }
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Updater.getsBetas ? Updater.betaFeed : nil
    }

    /// Your spaces, tabs, favorites and history are copied aside first, so a version that goes wrong can be undone.
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        ProfileBackup.make()
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

    private static var folder: URL { Paths.support.appendingPathComponent("Backups", isDirectory: true) }

    /// The backups, newest first.
    static var all: [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return found.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static var latest: URL? { all.first }

    /// When the newest backup was made, from its name.
    static var latestDate: Date? {
        latest.flatMap { stamp.date(from: String($0.lastPathComponent.prefix(19))) }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }()

    /// Named for when it was made and the version it was made from.
    static func make() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let target = folder.appendingPathComponent("\(stamp.string(from: Date())) \(version)", isDirectory: true)
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: target, withIntermediateDirectories: true)) != nil else { return }
        for name in files {
            let source = Paths.support.appendingPathComponent(name)
            if manager.fileExists(atPath: source.path) { try? manager.copyItem(at: source, to: target.appendingPathComponent(name)) }
        }
        for old in all.dropFirst(kept) { try? manager.removeItem(at: old) }
    }

    /// Puts the newest backup back the next time Zigzag starts, before anything reads the profile, then restarts
    /// Zigzag so that's now.
    @MainActor static func restoreLatestAndRelaunch() {
        guard let latest else { return }
        try? latest.lastPathComponent.write(to: folder.appendingPathComponent(restoreMarker), atomically: true, encoding: .utf8)
        let app = Bundle.main.bundleURL
        AppDelegate.quitConfirmed = true
        // The new copy waits for this one to finish saving before it starts reading.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(app.path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// At launch: if a restore was asked for, the backup's files replace the profile's.
    static func restoreIfAsked() {
        let manager = FileManager.default
        let marker = folder.appendingPathComponent(restoreMarker)
        guard let name = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? manager.removeItem(at: marker)
        let source = folder.appendingPathComponent(name, isDirectory: true)
        guard manager.fileExists(atPath: source.path) else { return }
        for file in files {
            let from = source.appendingPathComponent(file), to = Paths.support.appendingPathComponent(file)
            try? manager.removeItem(at: to)
            if manager.fileExists(atPath: from.path) { try? manager.copyItem(at: from, to: to) }
        }
    }
}

import AppKit

/// An update restarting Zigzag puts back exactly what was open: every browser window with its spaces, tabs and
/// splits (the saved session, written as the update asks to restart), and the Zigzag Mini windows, which a plain quit
/// lets go. What was open is noted in a file the next launch reads once and removes.
enum UpdateRelaunch {
    /// A Zigzag Mini window, as it was.
    nonisolated struct Mini: Codable, Equatable, Sendable {
        var url: URL
        var title: String
        var spaceID: UUID
        var frame: [Double]
        var keepOnTop: Bool
        /// Its back/forward list and place on the page.
        var interactionState: Data?
    }

    nonisolated struct Saved: Codable, Equatable, Sendable {
        var at: Date
        /// Browser windows were showing; false when only Zigzag Mini was (opened for a link), or no window at all.
        var browserWindowsOpen: Bool
        var minis: [Mini]
    }

    /// What launch brings back.
    nonisolated struct Plan: Equatable, Sendable {
        var restoresSession: Bool
        /// The saved browser windows stay waiting until something asks for one (`WindowManager.sessionWaiting`).
        var sessionWaiting: Bool
        var restoresMinis: Bool
    }

    /// A note older than this isn't from the restart that's launching now (an update that never came back up).
    nonisolated static let freshFor: TimeInterval = 30 * 60

    nonisolated static var file: URL { Paths.file("UpdateRelaunch.json") }

    /// The launch's choice. Restarted for an update: what was open, whatever else would decide (onboarding not
    /// marked done, a link for Zigzag Mini). Otherwise the usual: the session, unless onboarding comes first or
    /// Zigzag opened for Zigzag Mini or an installed site alone.
    nonisolated static func plan(relaunch: Saved?, now: Date, needsOnboarding: Bool, miniOnly: Bool, webAppOnly: Bool) -> Plan {
        if let relaunch, case let age = now.timeIntervalSince(relaunch.at), age > -60, age < freshFor {
            // Nothing open at all (every window closed): the browser windows, as any launch.
            let browsers = relaunch.browserWindowsOpen || relaunch.minis.isEmpty
            return Plan(restoresSession: browsers, sessionWaiting: !browsers, restoresMinis: !relaunch.minis.isEmpty)
        }
        let waiting = miniOnly || webAppOnly
        return Plan(restoresSession: !needsOnboarding && !waiting, sessionWaiting: waiting, restoresMinis: false)
    }

    /// Sparkle is about to quit Zigzag to install an update and open it again: what's open is written down now, the
    /// session on disk before Sparkle goes on, and the quit isn't asked about.
    static func prepare() {
        AppDelegate.quitConfirmed = true
        let manager = WindowManager.shared
        let browsers = !manager.sessionWaiting && manager.controllers.contains { !$0.tabManager.isPrivate }
        write(Saved(at: Date(), browserWindowsOpen: browsers, minis: MiniWindowController.all.compactMap(\.savedForRelaunch)))
        manager.saveNow(synchronously: true)
    }

    nonisolated static func write(_ saved: Saved, to url: URL = file) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The note from the restart, read once: it's removed as it's read.
    nonisolated static func take(from url: URL = file) -> Saved? {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }
}

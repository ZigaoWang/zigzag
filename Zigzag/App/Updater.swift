import AppKit
import Sparkle

/// Automatic updates via Sparkle. Checks daily and installs quietly on quit; no prompts unless you ask.
final class Updater {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?
    private let relaunch = RelaunchDelegate()

    /// Only signed release builds with a feed key can update; debug builds stay put.
    private var isConfigured: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty
    }

    func start() {
        guard isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: relaunch, userDriverDelegate: nil)
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

/// Restarting to finish an update isn't a quit to ask about.
private final class RelaunchDelegate: NSObject, SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { AppDelegate.quitConfirmed = true }
    }
}

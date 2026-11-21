import Foundation

/// What a launch does with the last session: pick it up, or start with one fresh window, the saved session left for
/// Window › Reopen Last Window (#433). Reopening is the default, so nothing changes for anyone who never opens Settings.
enum LaunchChoice: String, CaseIterable, Sendable {
    case resume, fresh

    /// Kept in the app's defaults, beside the other settings.
    static var choice: LaunchChoice {
        get { LaunchChoice(rawValue: defaults.string(forKey: key) ?? "") ?? .resume }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    /// What keeps it, so a test can swap in its own suite instead of the dev app's defaults.
    static var defaults: UserDefaults = .standard

    static let key = "LaunchChoice"
}

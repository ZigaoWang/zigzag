import Foundation

/// Settings for showing a shift-clicked link in the page instead of a separate Mini window.
enum InPageMiniSettings {
    static let key = "InPageMini"
    static var defaults: UserDefaults = .standard

    static var isEnabled: Bool {
        get { isEnabled(in: defaults) }
        set { setEnabled(newValue, in: defaults) }
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setEnabled(_ on: Bool, in defaults: UserDefaults) {
        defaults.set(on, forKey: key)
    }
}

/// Where the in-page Mini may appear: only in the frontmost, visible browser window on the active Space.
enum InPageMiniPolicy {
    static func shouldDock(enabled: Bool, windowIsKey: Bool, windowIsVisible: Bool,
                           windowIsMiniaturized: Bool, windowIsOnActiveSpace: Bool) -> Bool {
        enabled && windowIsKey && windowIsVisible && !windowIsMiniaturized && windowIsOnActiveSpace
    }
}

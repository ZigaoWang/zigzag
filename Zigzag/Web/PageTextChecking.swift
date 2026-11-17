import AppKit

/// Spelling, grammar and substitution choices for pages are the app's, as in Safari (#296): unticking Correct
/// Spelling Automatically (Edit › Spelling and Grammar, or a field's right-click menu) holds for every page, window
/// and relaunch.
///
/// WebKit keeps the choice for the whole app (its `Web…Enabled` user defaults, which it writes as you choose) but
/// hands it only to the page you chose it in: every other page, and the waiting process the next page opens in,
/// keeps the old one until Zigzag quits. Any of the Mac's own substitution notifications makes WebKit send its state,
/// all of it, to every page, so each change to one of those defaults posts one.
///
/// Until you choose, Correct Spelling Automatically follows the Mac's (System Settings › Keyboard › Text Input), as
/// in Safari: WebKit by itself would follow the Mac's Text Replacement setting there instead.
@MainActor
final class PageTextChecking {
    static let shared = PageTextChecking()

    /// WebKit's keys for its choices, in the app's user defaults.
    static let keys = ["WebContinuousSpellCheckingEnabled", "WebGrammarCheckingEnabled", "WebAutomaticSpellingCorrectionEnabled",
                       "WebAutomaticQuoteSubstitutionEnabled", "WebAutomaticDashSubstitutionEnabled", "WebAutomaticLinkDetectionEnabled",
                       "WebAutomaticTextReplacementEnabled", "WebSmartListsEnabled"]
    static let spellingCorrectionKey = "WebAutomaticSpellingCorrectionEnabled"

    private let defaults: UserDefaults
    private let center: NotificationCenter
    private let systemCorrects: () -> Bool
    private var last: [String: Bool] = [:]
    private var observers: [NSObjectProtocol] = []
    private var sending = false

    init(defaults: UserDefaults = .standard, center: NotificationCenter = .default,
         systemCorrects: @escaping () -> Bool = { NSSpellChecker.isAutomaticSpellingCorrectionEnabled }) {
        self.defaults = defaults
        self.center = center
        self.systemCorrects = systemCorrects
    }

    /// Before any page is made: WebKit reads its choices once, as the first one is.
    func start() {
        guard observers.isEmpty else { return }
        followSystem()
        last = current()
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.defaultsChanged() }
        })
        // Changed in System Settings while Zigzag runs: pages follow it, if you haven't chosen here. Registered before
        // WebKit's own observer (made with its first page), so WebKit reads the new value.
        observers.append(center.addObserver(forName: NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.followSystem() }
        })
    }

    /// Right away on the main thread, where WebKit changes its defaults; a change made on another goes there after.
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
    }

    /// The Mac's setting stands in for a choice you haven't made (a registered default, below one you set).
    func followSystem() {
        defaults.register(defaults: [Self.spellingCorrectionKey: systemCorrects()])
    }

    func current() -> [String: Bool] {
        Self.keys.reduce(into: [:]) { values, key in values[key] = (defaults.object(forKey: key) as? NSNumber)?.boolValue }
    }

    /// How many times the pages have been sent WebKit's state.
    private(set) var sent = 0

    private func defaultsChanged() {
        guard !sending else { return }
        let now = current()
        guard now != last else { return }
        last = now
        sending = true
        defer { sending = false }
        sent += 1
        center.post(name: NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification, object: nil)
    }
}

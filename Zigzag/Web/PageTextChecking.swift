import AppKit

/// Makes spelling, grammar and substitution choices app-wide, as in Safari (#296). WebKit saves the choice in its
/// `Web…Enabled` user defaults but only applies it to the page it was made in; other pages and the prewarmed process
/// keep the old value until quit. Any of the Mac's substitution notifications makes WebKit resend all its state to
/// every page, so each change to those defaults posts one. Until you choose, Correct Spelling Automatically follows
/// System Settings › Keyboard › Text Input as in Safari; WebKit alone would follow Text Replacement instead.
@MainActor
final class PageTextChecking {
    static let shared = PageTextChecking()

    /// WebKit's user defaults keys.
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

    /// Before any page exists: WebKit reads its choices once, when the first is made.
    func start() {
        guard observers.isEmpty else { return }
        followSystem()
        last = current()
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.defaultsChanged() }
        })
        // System Settings changes apply unless you've chosen here. Registered before WebKit's own observer (created
        // with its first page) so WebKit reads the new value.
        observers.append(center.addObserver(forName: NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.followSystem() }
        })
    }

    /// Runs inline on main, where WebKit changes its defaults; otherwise hops there.
    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) } else { DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
    }

    /// Registers the Mac's setting as the default, below any choice you made.
    func followSystem() {
        defaults.register(defaults: [Self.spellingCorrectionKey: systemCorrects()])
    }

    func current() -> [String: Bool] {
        Self.keys.reduce(into: [:]) { values, key in values[key] = (defaults.object(forKey: key) as? NSNumber)?.boolValue }
    }

    /// How many times state was sent to pages.
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

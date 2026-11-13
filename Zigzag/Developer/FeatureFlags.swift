import Foundation
import WebKit

/// WebKit's feature flags (#173), as Safari's Develop › Feature Flags lists them: the switches the Mac's own WebKit
/// has for features that are new, being tried or for debugging, each with WebKit's name, a line about it and its
/// default. They're in Settings › Developer while Developer Mode's main switch is on.
///
/// Only a flag someone changed is kept (its key and whether it's on); every other one stays WebKit's default, which can
/// change with each macOS update. The changes are Zigzag's, for every profile, as Safari's are its own, and they're
/// set on every page Zigzag makes (`WebKitSetup.configure`) while Developer Mode is on. Turning a flag back to its
/// default, or Reset to Defaults, forgets it.
///
/// WebKit lists its flags only through unpublished API (`+[WKPreferences _features]`, `_WKFeature`,
/// `-[WKPreferences _setEnabled:forFeature:]`), so every call is made only when WebKit still answers it, and with no
/// list there's no group in Settings at all.
enum FeatureFlags {
    /// One of WebKit's flags.
    struct Flag: Equatable {
        /// WebKit's own name for it, as its preferences say it: `CSSAnchorPositioningEnabled`.
        let key: String
        /// What WebKit calls it to people, never translated: "CSS Anchor Positioning".
        let name: String
        /// WebKit's line about it, empty when it has none.
        let details: String
        let status: Status
        /// On or off when nothing has changed it.
        let defaultValue: Bool
    }

    /// How far along WebKit says a flag is (`_WKFeatureStatus`), in its own order.
    enum Status: Int, CaseIterable {
        /// For the app that embeds WebKit to set: Zigzag's own choices. Never listed.
        case embedder = 0
        case unstable, `internal`, developer, testable, preview, stable, mature

        /// The order of the groups in Settings: what's on its way first, as Safari lists them.
        static let listed: [Status] = [.stable, .preview, .testable, .developer]
        /// Behind Show All: flags for WebKit's own engineers, unfinished ones, and ones in use for over a year.
        static let more: [Status] = [.mature, .unstable, .internal]

        var title: String {
            switch self {
            case .embedder: ""
            case .stable: String(localized: "Stable", comment: "A heading in Settings › Developer › Feature Flags, as Safari has it: WebKit features that are on by default and ready.")
            case .preview: String(localized: "Preview", comment: "A heading in Settings › Developer › Feature Flags, as Safari has it: WebKit features on in Safari Technology Preview, not ready to ship.")
            case .testable: String(localized: "Testable", comment: "A heading in Settings › Developer › Feature Flags, as Safari has it: WebKit features ready to test, not ready to ship.")
            case .developer: String(localized: "featureflags.developer", defaultValue: "Developer",
                                    comment: "A heading in Settings › Developer › Feature Flags, as Safari has it: WebKit's tools for people who build websites.")
            case .mature: String(localized: "Mature", comment: "A heading in Settings › Developer › Feature Flags: WebKit features on by default and in use for more than a year.")
            case .unstable: String(localized: "Unstable", comment: "A heading in Settings › Developer › Feature Flags: WebKit features still being built, which can break pages.")
            case .internal: String(localized: "Internal", comment: "A heading in Settings › Developer › Feature Flags: tools for debugging WebKit itself.")
            }
        }
    }

    /// Where WebKit's flags come from and are set. Tests use a list of their own.
    protocol Engine: AnyObject {
        /// The flags, in WebKit's order; nil when this WebKit doesn't list them.
        var flags: [Flag]? { get }
        /// Sets one on or off in `preferences`, if WebKit still has it.
        func set(_ on: Bool, key: String, in preferences: WKPreferences)
    }

    /// Where the changes are kept; tests use their own.
    static var defaults: UserDefaults = .standard
    static var engine: Engine = WebKitFeatures()
    /// A flag changed, or every one went back to its default.
    static let changed = Signal<Void>()

    private static let key = "WebKitFeatureFlags"

    /// The flags you can change, the ones WebKit keeps to itself left out; nil when there's no list to show.
    static var flags: [Flag]? {
        engine.flags.map { $0.filter { $0.status != .embedder && !$0.name.isEmpty } }
    }

    /// Whether Settings has the group: WebKit lists its flags, and lets them be set.
    static var isAvailable: Bool { !(flags ?? []).isEmpty }

    /// The flags someone changed, by key: whether each is on.
    static var overrides: [String: Bool] {
        (defaults.dictionary(forKey: key) ?? [:]).compactMapValues { $0 as? Bool }
    }

    static var hasOverrides: Bool { !overrides.isEmpty }

    /// Whether a flag is on: as it was changed to, or WebKit's default.
    static func isOn(_ flag: Flag) -> Bool { overrides[flag.key] ?? flag.defaultValue }

    static func isChanged(_ flag: Flag) -> Bool { overrides[flag.key] != nil }

    /// Turns a flag on or off. Back to its default, it's forgotten, so a later WebKit's default holds for it again.
    static func set(_ on: Bool, for flag: Flag) {
        var all = overrides
        if on == flag.defaultValue { all[flag.key] = nil } else { all[flag.key] = on }
        guard all != overrides else { return }
        save(all)
        applyToOpenPages(flag.key, on)
    }

    /// Every flag back to WebKit's default.
    static func reset() {
        let was = overrides
        guard !was.isEmpty else { return }
        save([:])
        let defaults = Dictionary((flags ?? []).map { ($0.key, $0.defaultValue) }, uniquingKeysWith: { a, _ in a })
        for key in was.keys { if let value = defaults[key] { applyToOpenPages(key, value) } }
    }

    private static func save(_ all: [String: Bool]) {
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
        changed.send()
    }

    /// What a new page is made with: every change, while Developer Mode is on. A flag this WebKit no longer has is
    /// kept and passed over.
    static func apply(to preferences: WKPreferences) {
        guard DeveloperTools.isOn else { return }
        let all = overrides
        guard !all.isEmpty else { return }
        for (key, on) in all { engine.set(on, key: key, in: preferences) }
    }

    /// Pages already open take a change too, so reloading one is enough: each one's preferences are its own and live.
    /// Many flags are read only as a page loads, which is why Settings says to reload.
    private static func applyToOpenPages(_ key: String, _ on: Bool) {
        guard DeveloperTools.isOn else { return }
        for webView in openWebViews { engine.set(on, key: key, in: webView.configuration.preferences) }
    }

    /// Every page in a browser window, a sleeping tab's left alone: it wakes with what's set then.
    private static var openWebViews: [WKWebView] {
        WindowManager.shared.controllers.flatMap(\.tabManager.allTabs).compactMap(\.webView)
    }

    /// Reloads every page that's showing a website in a browser window, so a change takes effect. Zigzag's own pages
    /// (Settings, History) and sleeping tabs are left as they are.
    static func reloadAllTabs() {
        for tab in WindowManager.shared.controllers.flatMap(\.tabManager.allTabs) {
            guard let webView = tab.webView, let scheme = webView.url?.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { continue }
            webView.reload()
        }
    }

    /// The flags of a status, in WebKit's order, whose name, key or line has every word of a search.
    static func flags(_ status: Status, in all: [Flag], matching words: [String]) -> [Flag] {
        all.filter { flag in
            flag.status == status && words.allSatisfy { word in
                [flag.name, flag.key, flag.details].contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }
}

/// The flags of the WebKit on this Mac, read and set through its unpublished API, each call only when WebKit still
/// answers it.
final class WebKitFeatures: FeatureFlags.Engine {
    /// The class that lists them: WKPreferences, or a stand-in in tests.
    private let source: AnyObject
    /// WebKit's own objects by key, which `_setEnabled:forFeature:` takes; read once.
    private var features: [String: NSObject]?
    private var listed: [FeatureFlags.Flag]?
    private var hasRead = false

    init(source: AnyObject = WKPreferences.self) { self.source = source }

    static let listSelector = NSSelectorFromString("_features")
    static let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
    private static let fields = ["key", "name", "details", "status", "defaultValue"]

    var flags: [FeatureFlags.Flag]? {
        read()
        return listed
    }

    private func read() {
        guard !hasRead else { return }
        hasRead = true
        // A list that can't be set is no use: both, or nothing.
        guard source.responds(to: Self.listSelector), WKPreferences.instancesRespond(to: Self.setSelector),
              let list = source.perform(Self.listSelector)?.takeUnretainedValue() as? [NSObject] else { return }
        var features: [String: NSObject] = [:]
        var flags: [FeatureFlags.Flag] = []
        for feature in list {
            // Each field only if the object has it: a WebKit that renamed one lists nothing rather than guessing.
            guard Self.fields.allSatisfy({ feature.responds(to: NSSelectorFromString($0)) }),
                  let key = feature.value(forKey: "key") as? String, !key.isEmpty,
                  let status = (feature.value(forKey: "status") as? Int).flatMap(FeatureFlags.Status.init(rawValue:)),
                  let defaultValue = feature.value(forKey: "defaultValue") as? Bool else { continue }
            if feature.responds(to: NSSelectorFromString("isHidden")), feature.value(forKey: "hidden") as? Bool == true { continue }
            guard features[key] == nil else { continue }
            features[key] = feature
            flags.append(FeatureFlags.Flag(key: key, name: feature.value(forKey: "name") as? String ?? "",
                                           details: feature.value(forKey: "details") as? String ?? "",
                                           status: status, defaultValue: defaultValue))
        }
        self.features = features
        listed = flags
    }

    func set(_ on: Bool, key: String, in preferences: WKPreferences) {
        read()
        guard let feature = features?[key], preferences.responds(to: Self.setSelector) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        unsafeBitCast(preferences.method(for: Self.setSelector), to: SetEnabled.self)(preferences, Self.setSelector, on, feature)
    }
}

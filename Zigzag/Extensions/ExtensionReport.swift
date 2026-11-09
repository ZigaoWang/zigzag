import AppKit
import WebKit

/// What an extension will be able to do, and what it asks for that Zigzag can't give it, in plain words.
/// Shown before installing and in Settings.
///
/// The limits come from WebKit itself: it quietly drops permissions it doesn't support, so anything the
/// manifest asks for that WebKit didn't recognize is something that won't work here.
@available(macOS 15.4, *)
struct ExtensionReport {
    struct Line: Hashable {
        let symbol: String
        let text: String
    }

    /// What it can do once added, most important first. Empty for an extension that asks for nothing notable.
    let abilities: [Line]
    /// Features it asks for that won't work in Zigzag, as short names ("Side panel", "Signing in").
    let limits: [String]

    init(extension ext: WKWebExtension, manifest: [String: Any], id: String) {
        let requested = Self.strings(manifest, ["permissions", "optional_permissions"])
        let recognized = Set(ext.requestedPermissions.map(\.rawValue)).union(ext.optionalPermissions.map(\.rawValue))
        // Not a permission, but worth saying up front: it changes what ⌘T does.
        let replacesNewTab = (manifest["chrome_url_overrides"] as? [String: Any])?["newtab"] != nil
        // Nor is a search engine of its own, offered once it's added.
        let searchEngine = ExtensionSearchProvider(manifest: manifest, extensionID: id)?.name
        abilities = Self.abilities(permissions: requested, patterns: ext.allRequestedMatchPatterns.map(\.string), id: id, replacesNewTab: replacesNewTab, searchEngine: searchEngine)

        var limits: [String] = ExtensionProfile.profile(for: id)?.knownIssue.map { [$0] } ?? []
        let covered = (ExtensionProfile.profile(for: id)?.coveredPermissions ?? []).union(ExtensionBridgeScript.permissions)
        for permission in requested.subtracting(recognized).subtracting(covered).sorted() {
            if let name = Self.limitNames[permission], !limits.contains(name) { limits.append(name) }
        }
        for (permission, name) in Self.partLimits where requested.contains(permission) && !limits.contains(name) { limits.append(name) }
        for (key, name) in Self.manifestLimits where manifest[key] != nil && !limits.contains(name) { limits.append(name) }
        self.limits = limits
    }

    /// Only what a new version asks for beyond the old one, for approving an update.
    init(newIn ext: WKWebExtension, manifest: [String: Any], comparedTo old: [String: Any], id: String) {
        let full = ExtensionReport(extension: ext, manifest: manifest, id: id)
        let oldPatterns = Self.strings(old, ["host_permissions", "optional_host_permissions"])
            .union(Self.strings(old, ["permissions"]).filter { $0.contains("://") || $0 == "<all_urls>" })
        let oldLines = Set(Self.abilities(permissions: Self.strings(old, ["permissions", "optional_permissions"]), patterns: Array(oldPatterns), id: id,
                                          replacesNewTab: (old["chrome_url_overrides"] as? [String: Any])?["newtab"] != nil,
                                          searchEngine: ExtensionSearchProvider(manifest: old, extensionID: id)?.name))
        abilities = full.abilities.filter { !oldLines.contains($0) }
        limits = full.limits
    }

    /// What an extension asking for more (`permissions.request`) would gain, for asking you first. Every permission
    /// asked for shows in a line, if only in the last one.
    init(requesting permissions: Set<String>, id: String) {
        var lines = Self.abilities(permissions: permissions, patterns: [], id: id)
        var worded: Set<String> = ["nativeMessaging", "history", "tabs", "webNavigation", "bookmarks", "downloads", "notifications",
                                   "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "userScripts", "cookies", "proxy", "management"]
        if permissions.contains("downloads") { worded.insert("downloads.open") }
        if permissions.contains("tabCapture") {
            lines.append(Line(symbol: "waveform", text: String(localized: "Hear the sound of tabs you use it on", comment: "One thing an extension can do, in the sheet that asks before it gets more access.")))
        }
        if permissions.contains("topSites"), !permissions.contains("history") {
            lines.append(Line(symbol: "clock", text: String(localized: "See the sites you visit most", comment: "One thing an extension can do, in the sheet that asks before it gets more access.")))
        }
        if !permissions.isDisjoint(with: ["webRequest", "webRequestBlocking", "webRequestAuthProvider"]) {
            lines.append(Line(symbol: "network", text: String(localized: "See what sites load as you browse", comment: "One thing an extension can do, in the sheet that asks before it gets more access: watch the requests pages make.")))
        }
        if permissions.contains("clipboardRead") {
            lines.append(Line(symbol: "doc.on.clipboard", text: String(localized: "Read what you copy", comment: "One thing an extension can do, in the sheet that asks before it gets more access.")))
        }
        worded.formUnion(["tabCapture", "topSites", "webRequest", "webRequestBlocking", "webRequestAuthProvider", "clipboardRead"])
        if !permissions.subtracting(worded).isEmpty {
            lines.append(Line(symbol: "puzzlepiece.extension", text: String(localized: "Use more of Zigzag’s features", comment: "One thing an extension can do, in the sheet that asks before it gets more access: stands in for permissions with no line of their own.")))
        }
        abilities = lines
        limits = []
    }

    /// Permissions an extension gets only when you say so, when it asks for one later: what Chrome warns about, and
    /// what Zigzag's bridge opens (history, downloads, a proxy, tab sound, sites' sign-ins). Others it gets quietly.
    static let askedPermissions: Set<String> = [
        "bookmarks", "clipboardRead", "contentSettings", "cookies", "debugger", "declarativeNetRequest", "declarativeNetRequestFeedback",
        "declarativeNetRequestWithHostAccess", "desktopCapture", "downloads", "downloads.open", "geolocation", "history", "management",
        "nativeMessaging", "notifications", "pageCapture", "privacy", "proxy", "readingList", "sessions", "tabCapture", "tabGroups", "tabs",
        "topSites", "userScripts", "webNavigation", "webRequest", "webRequestAuthProvider", "webRequestBlocking",
    ]

    private static func strings(_ manifest: [String: Any], _ keys: [String]) -> Set<String> {
        Set(keys.flatMap { manifest[$0] as? [String] ?? [] })
    }

    // MARK: Plain words

    private static func abilities(permissions: Set<String>, patterns: [String], id: String, replacesNewTab: Bool = false, searchEngine: String? = nil) -> [Line] {
        var lines: [Line] = []
        let hosts = patterns.compactMap(host(of:))
        if patterns.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }) {
            lines.append(Line(symbol: "globe", text: String(localized: "Read and change what you see on every website", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        } else if let first = hosts.first {
            let others = Set(hosts).count - 1
            lines.append(Line(symbol: "globe", text: others > 0
                ? String(localized: "Read and change what you see on \(first) and \(others) other sites",
                         comment: "One thing an extension can do, in its install sheet and in Settings. The first placeholder is a site, like youtube.com; the second counts the other sites.")
                : String(localized: "Read and change what you see on \(first)",
                         comment: "One thing an extension can do, in its install sheet and in Settings. The placeholder is a site, like youtube.com.")))
        }
        if permissions.contains("nativeMessaging") {
            lines.append(Line(symbol: "macwindow", text: appLine(for: id)))
        }
        if permissions.contains("history") {
            lines.append(Line(symbol: "clock", text: String(localized: "Read and change your browsing history", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        } else if permissions.contains("tabs") || permissions.contains("webNavigation") {
            lines.append(Line(symbol: "clock", text: String(localized: "See the sites you visit", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if permissions.contains("bookmarks") {
            lines.append(Line(symbol: "pin", text: String(localized: "Read and change your pinned pages, folders and favorites", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if permissions.contains("downloads") {
            lines.append(Line(symbol: "arrow.down.circle", text: permissions.contains("downloads.open") ? String(localized: "Download files and open them", comment: "One thing an extension can do, listed in its install sheet and in Settings.") : String(localized: "Download files and manage your downloads", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if permissions.contains("notifications") {
            lines.append(Line(symbol: "bell", text: String(localized: "Show notifications", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if replacesNewTab {
            lines.append(Line(symbol: "plus.square", text: String(localized: "Show its own page when you open a new tab", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if let searchEngine {
            lines.append(Line(symbol: "magnifyingglass", text: String(localized: "Offer \(searchEngine) as your search engine", comment: "One thing an extension can do, listed in its install sheet and in Settings. The name is the search engine's, like ChatGPT.")))
        }
        if permissions.contains("declarativeNetRequest") || permissions.contains("declarativeNetRequestWithHostAccess") {
            lines.append(Line(symbol: "hand.raised", text: String(localized: "Block content on pages", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        // Installing it is the go-ahead Chrome asks for separately ("Allow user scripts"), so the sheet says so.
        if permissions.contains("userScripts") {
            lines.append(Line(symbol: "curlybraces", text: String(localized: "Run scripts you add on the sites it can access", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if permissions.contains("cookies") {
            lines.append(Line(symbol: "lock", text: String(localized: "Read and change cookies on the sites it can access", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if permissions.contains("proxy") {
            lines.append(Line(symbol: "network", text: String(localized: "Send your browsing through a proxy server", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        if permissions.contains("management") {
            lines.append(Line(symbol: "puzzlepiece.extension", text: String(localized: "See your other extensions", comment: "One thing an extension can do, listed in its install sheet and in Settings.")))
        }
        return lines
    }

    /// "youtube.com" from "*://*.youtube.com/*".
    private static func host(of pattern: String) -> String? {
        guard let range = pattern.range(of: "://") else { return nil }
        var host = pattern[range.upperBound...].prefix { $0 != "/" }
        if host.hasPrefix("*.") { host = host.dropFirst(2) }
        guard !host.isEmpty, host != "*", host != "localhost", host != "127.0.0.1" else { return nil }
        return String(host)
    }

    /// "Talk to the 1Password app on your Mac": a whole line for each app, so each reads right in any language.
    private static func appLine(for id: String) -> String {
        switch id {
        case ExtensionStore.onePasswordID: String(localized: "Talk to the 1Password app on your Mac", comment: "One thing an extension can do, in its install sheet and in Settings: exchange messages with an app installed on the Mac.")
        case "nngceckbapebfimnlniiiahkandclblb": String(localized: "Talk to the Bitwarden app on your Mac", comment: "One thing an extension can do, in its install sheet and in Settings: exchange messages with an app installed on the Mac.")
        default: String(localized: "Talk to an app on your Mac", comment: "One thing an extension can do, in its install sheet and in Settings: exchange messages with an app installed on the Mac.")
        }
    }

    /// Permissions WebKit doesn't support, by the feature a person would notice is missing.
    private static let limitNames: [String: String] = [
        "sidePanel": String(localized: "Side panel", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "identity": String(localized: "Signing in with your account", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "identity.email": String(localized: "Signing in with your account", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "notifications": String(localized: "Notifications", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "downloads": String(localized: "Downloads", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "downloads.open": String(localized: "Downloads", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "idle": String(localized: "Knowing when you’re away", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "offscreen": String(localized: "Background audio and clipboard", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "webRequestBlocking": String(localized: "Blocking requests the old way", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "history": String(localized: "Your browsing history", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "bookmarks": String(localized: "Your bookmarks", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "topSites": String(localized: "Your top sites", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "tabGroups": String(localized: "Tab groups", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "fontSettings": String(localized: "Font settings", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "tts": String(localized: "Reading aloud", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "ttsEngine": String(localized: "Reading aloud", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "geolocation": String(localized: "Your location", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "clipboardRead": String(localized: "Reading what you copy", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "management": String(localized: "Managing other extensions", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "privacy": String(localized: "Privacy settings", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "debugger": String(localized: "Debugging pages", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "pageCapture": String(localized: "Saving pages", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "desktopCapture": String(localized: "Recording your screen", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "tabCapture": String(localized: "Recording tabs", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "system.display": String(localized: "Display information", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
        "power": String(localized: "Keeping your Mac awake", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag."),
    ]

    /// The part of an API the bridge answers that still won't work, by the permission that brings it.
    private static let partLimits: [(String, String)] = [
        // Fixed proxy servers work; WebKit has nothing to run a proxy auto-config script on.
        ("proxy", String(localized: "Proxy scripts (PAC)", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag: proxy auto-config scripts, which choose a proxy for each site.")),
    ]

    /// Manifest features with no WebKit equivalent.
    private static let manifestLimits: [(String, String)] = [
        ("omnibox", String(localized: "Address bar keyword", comment: "Feature name in the list of things an extension uses that won’t work in Zigzag.")),
    ]
}

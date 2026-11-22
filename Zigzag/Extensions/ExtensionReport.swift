import AppKit
import WebKit

/// Which browser a package was built for, as its record keeps it.
nonisolated enum ExtensionKind: String, Codable, Sendable {
    case chromium
    case firefox
}

/// What an extension will be able to do, and what it asks for that Zigzag can't give it, in plain words.
/// Shown before installing and in Settings.
///
/// Limits come from the compatibility claims over `chrome-api.json`; the sheet shows the lines they name. A permission
/// WebKit drops that no claim covers is listed by name.
@available(macOS 15.4, *)
struct ExtensionReport {
    struct Line: Hashable {
        let symbol: String
        let text: String
    }

    /// What it can do once added, most important first. Empty for an extension that asks for nothing notable.
    let abilities: [Line]
    /// Requested features that won't work in Zigzag, worded by the claims.
    let limits: [CompatibilityLimit]
    /// What the lines were worded from, so several extensions' can be put together.
    private var asked = Asked()

    private struct Asked {
        var permissions: Set<String> = []
        var patterns: Set<String> = []
        var replacesNewTab = false
        var searchEngines: [String] = []
        var ids: Set<String> = []
    }

    /// `firefox`: the package is a Firefox one (an .xpi), which words some limits differently.
    init(extension ext: WKWebExtension, manifest: [String: Any], id: String, firefox: Bool = false) {
        let requested = Self.strings(manifest, ["permissions", "optional_permissions"])
        let recognized = Set(ext.requestedPermissions.map(\.rawValue)).union(ext.optionalPermissions.map(\.rawValue))
        // Not a permission, but worth saying up front: it changes what ⌘T does.
        let replacesNewTab = (manifest["chrome_url_overrides"] as? [String: Any])?["newtab"] != nil
        // Nor is a search engine of its own, offered once it's added.
        let searchEngine = ExtensionSearchProvider(manifest: manifest, extensionID: id)?.name
        let patterns = ext.allRequestedMatchPatterns.map(\.string)
        abilities = Self.abilities(permissions: requested, patterns: patterns, id: id, replacesNewTab: replacesNewTab, searchEngine: searchEngine)
        asked = Asked(permissions: requested, patterns: Set(patterns), replacesNewTab: replacesNewTab, searchEngines: searchEngine.map { [$0] } ?? [], ids: [id])
        limits = Self.lines(for: manifest, requested: requested, recognized: recognized, id: id, log: true, firefox: firefox)
    }

    /// Settings' lines for an extension, without building the whole report. The overlay is decoded once
    /// (`ExtensionCompatibility.shared`).
    static func limits(for ext: WKWebExtension, manifest: [String: Any], id: String, firefox: Bool = false) -> [CompatibilityLimit] {
        let requested = strings(manifest, ["permissions", "optional_permissions"])
        let recognized = Set(ext.requestedPermissions.map(\.rawValue)).union(ext.optionalPermissions.map(\.rawValue))
        return lines(for: manifest, requested: requested, recognized: recognized, id: id, log: true, firefox: firefox)
    }

    /// Claim lines for a manifest's permissions and keys, minus what a shim prelude covers, plus a line by name for
    /// permissions neither WebKit nor the claims know. Wording only; nothing grants or drops permissions.
    private static func lines(for manifest: [String: Any], requested: Set<String>, recognized: Set<String>,
                              id: String, log: Bool, firefox: Bool = false) -> [CompatibilityLimit] {
        var limits = claimedLines(for: requested, manifestKeys: manifestKeys(in: manifest), id: id, log: log)
        // Firefox's proxy API (proxy.onRequest, and proxy.settings in its own shape) has nothing here to run on.
        if firefox, requested.contains("proxy") {
            limits.append(CompatibilityLimit(catalogKey: firefoxProxyKey, group: "proxy", reason: .webkitMissing, status: .unsupported, source: "proxy"))
        }
        let covered = ExtensionShims.shim(for: id)?.coveredPermissions ?? []
        let claimed = ExtensionCompatibility.shared.overlay.map { Set($0.permissions.keys) } ?? []
        // A permission is a limit only if WebKit drops it; one WebKit supports with no claim still works. MV2 host patterns in
        // permissions aren't missing claims.
        let names = Set(requested.filter(Self.isPermissionName))
        for name in names.subtracting(recognized).subtracting(claimed).subtracting(covered).sorted() {
            limits.append(CompatibilityLimit(catalogKey: nil, group: name, reason: .webkitMissing,
                                             status: .unsupported, source: name))
            if log { ExtensionLog.write("\(id): \(name) is not in the compatibility claims; reported by name") }
        }
        return limits
    }

    /// Overlay lines for these permissions and keys, minus those a shim prelude covers well enough.
    private static func claimedLines(for requested: Set<String>, manifestKeys: Set<String>, id: String,
                                     log: Bool) -> [CompatibilityLimit] {
        let shim = ExtensionShims.shim(for: id)
        let covered = shim?.coveredPermissions ?? []
        var limits = ExtensionCompatibility.shared.limits(forPermissions: requested, manifestKeys: manifestKeys)
        let hidden = limits.filter { covered.contains(permission(of: $0)) }
        limits.removeAll { covered.contains(permission(of: $0)) }
        if log {
            for limit in hidden {
                ExtensionLog.write("\(id): \(limit.text) is covered by the extension's prelude; not a limit")
            }
            if let knownIssue = shim?.knownIssue {
                ExtensionLog.write("\(id): a prelude-known issue has no compatibility claim: \(knownIssue)")
            }
        }
        return limits
    }

    /// Manifest keys with claim lines that this manifest uses.
    private static func manifestKeys(in manifest: [String: Any]) -> Set<String> {
        guard let overlay = ExtensionCompatibility.shared.overlay else { return [] }
        return Set(overlay.manifest.keys.filter { manifest[$0] != nil })
    }

    /// The permission a line belongs to: first component of its source (the permission itself, or a claim path such as
    /// `management.getSelf`).
    private static func permission(of limit: CompatibilityLimit) -> String {
        String(limit.source.prefix { $0 != "." })
    }

    static let firefoxProxyKey = "extension.limit.firefoxProxy"

    /// Whether a manifest string is a permission name, not an MV2 host pattern.
    private static func isPermissionName(_ name: String) -> Bool {
        !name.contains("://") && name != "<all_urls>" && !name.hasPrefix("*")
    }

    /// What several extensions added together will be able to do, worded once: "every website" once, not once
    /// for each of them. Each one's own limits stay with it.
    init(combining reports: [ExtensionReport]) {
        var all = Asked()
        for report in reports {
            all.permissions.formUnion(report.asked.permissions)
            all.patterns.formUnion(report.asked.patterns)
            all.replacesNewTab = all.replacesNewTab || report.asked.replacesNewTab
            all.searchEngines += report.asked.searchEngines.filter { !all.searchEngines.contains($0) }
            all.ids.formUnion(report.asked.ids)
        }
        // A password manager's line names its app only when it's the one asking.
        let id = all.ids.count == 1 ? all.ids.first ?? "" : ""
        var lines = Self.abilities(permissions: all.permissions, patterns: all.patterns.sorted(), id: id,
                                   replacesNewTab: all.replacesNewTab, searchEngine: all.searchEngines.first)
        if let index = lines.firstIndex(where: { $0.symbol == "magnifyingglass" }) {
            let more = all.searchEngines.dropFirst().map { engine in
                Line(symbol: "magnifyingglass", text: String(localized: "Offer \(engine) as your search engine", comment: "One thing an extension can do, listed in its install sheet and in Settings. The name is the search engine's, like ChatGPT."))
            }
            lines.insert(contentsOf: more, at: index + 1)
        }
        abilities = lines
        limits = []
        asked = all
    }

    /// Only what a new version asks for beyond the old one, for approving an update.
    init(newIn ext: WKWebExtension, manifest: [String: Any], comparedTo old: [String: Any], id: String) {
        let full = ExtensionReport(extension: ext, manifest: manifest, id: id)
        let oldPatterns = Self.strings(old, ["host_permissions", "optional_host_permissions"])
            .union(Self.strings(old, ["permissions"]).filter { $0.contains("://") || $0 == "<all_urls>" })
        let oldPermissions = Self.strings(old, ["permissions", "optional_permissions"])
        let oldLines = Set(Self.abilities(permissions: oldPermissions, patterns: Array(oldPatterns), id: id,
                                          replacesNewTab: (old["chrome_url_overrides"] as? [String: Any])?["newtab"] != nil,
                                          searchEngine: ExtensionSearchProvider(manifest: old, extensionID: id)?.name))
        abilities = full.abilities.filter { !oldLines.contains($0) }
        // Diff by catalog key: lines the old version had aren't new. Unclaimed permissions use their name as key, so only
        // newly requested ones show.
        let oldLimits = Set(Self.lines(for: old, requested: oldPermissions, recognized: [], id: id, log: false)
            .map(\.identity))
        limits = full.limits.filter { !oldLimits.contains($0.identity) }
    }

    /// What an extension asking for more (`permissions.request`) would gain, for asking you first. Every permission
    /// asked for shows in a line, if only in the last one.
    init(requesting permissions: Set<String>, patterns: [String] = [], id: String) {
        var lines = Self.abilities(permissions: permissions, patterns: patterns, id: id)
        // A site the install sheet leaves unnamed (localhost) is still named here.
        if let pattern = patterns.first, !lines.contains(where: { $0.symbol == "globe" }) {
            let site = String(pattern.components(separatedBy: "://").last?.prefix { $0 != "/" } ?? Substring(pattern))
            lines.insert(Line(symbol: "globe", text: String(localized: "Read and change what you see on \(site)",
                                                             comment: "One thing an extension can do, in its install sheet and in Settings. The placeholder is a site, like youtube.com.")), at: 0)
        }
        var worded: Set<String> = ["nativeMessaging", "history", "tabs", "webNavigation", "bookmarks", "downloads", "notifications",
                                   "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "userScripts", "cookies", "proxy", "management"]
        if permissions.contains("downloads") { worded.insert("downloads.open") }
        if permissions.contains("topSites"), !permissions.contains("history") {
            lines.append(Line(symbol: "clock", text: String(localized: "See the sites you visit most", comment: "One thing an extension can do, in the sheet that asks before it gets more access.")))
        }
        worded.formUnion(["tabCapture", "topSites", "webRequest", "webRequestBlocking", "webRequestAuthProvider", "clipboardRead",
                          "identity", "scripting", "offscreen"])
        if !permissions.subtracting(worded).isEmpty {
            lines.append(Line(symbol: "puzzlepiece.extension", text: String(localized: "Use more of Zigzag’s features", comment: "One thing an extension can do, in the sheet that asks before it gets more access: stands in for permissions with no line of their own.")))
        }
        abilities = lines
        limits = Self.claimedLines(for: permissions, manifestKeys: [], id: id, log: true)
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
        if permissions.contains("tabCapture") {
            lines.append(Line(symbol: "waveform", text: String(localized: "Hear the sound of tabs you use it on", comment: "One thing an extension can do, listed in its install sheet and in Settings, and in the sheet that asks before it gets more access.")))
        }
        if !permissions.isDisjoint(with: ["webRequest", "webRequestBlocking", "webRequestAuthProvider"]) {
            lines.append(Line(symbol: "network", text: String(localized: "See what sites load as you browse", comment: "One thing an extension can do, listed in its install sheet and in Settings, and in the sheet that asks before it gets more access: watch the requests pages make.")))
        }
        if permissions.contains("clipboardRead") {
            lines.append(Line(symbol: "doc.on.clipboard", text: String(localized: "Read what you copy", comment: "One thing an extension can do, listed in its install sheet and in Settings, and in the sheet that asks before it gets more access.")))
        }
        if permissions.contains("scripting") {
            lines.append(Line(symbol: "curlybraces", text: String(localized: "Run its own scripts on the sites it can access", comment: "One thing an extension can do, listed in its install sheet and in Settings: the scripting permission.")))
        }
        if permissions.contains("identity") || permissions.contains("identity.email") {
            lines.append(Line(symbol: "person.crop.circle", text: String(localized: "Open sign-in pages and get what sites send back", comment: "One thing an extension can do, listed in its install sheet and in Settings: the identity permission, which opens a site's sign-in page and hands the extension the answer.")))
        }
        if permissions.contains("offscreen") {
            lines.append(Line(symbol: "rectangle.dashed", text: String(localized: "Run hidden pages of its own in the background", comment: "One thing an extension can do, listed in its install sheet and in Settings: the offscreen permission, for pages you never see that can play sound or use the clipboard.")))
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

}

private extension CompatibilityLimit {
    /// Identity of a line across versions: its catalog key, or the raw permission when unclaimed.
    var identity: String { catalogKey ?? "permission:\(source)" }
}

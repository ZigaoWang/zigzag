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
        abilities = Self.abilities(permissions: requested, patterns: ext.allRequestedMatchPatterns.map(\.string), id: id)

        var limits: [String] = ExtensionProfile.profile(for: id)?.knownIssue.map { [$0] } ?? []
        let covered = ExtensionProfile.profile(for: id)?.coveredPermissions ?? []
        for permission in requested.subtracting(recognized).subtracting(covered).sorted() {
            if let name = Self.limitNames[permission], !limits.contains(name) { limits.append(name) }
        }
        for (key, name) in Self.manifestLimits where manifest[key] != nil && !limits.contains(name) { limits.append(name) }
        self.limits = limits
    }

    /// Only what a new version asks for beyond the old one, for approving an update.
    init(newIn ext: WKWebExtension, manifest: [String: Any], comparedTo old: [String: Any], id: String) {
        let full = ExtensionReport(extension: ext, manifest: manifest, id: id)
        let oldPatterns = Self.strings(old, ["host_permissions", "optional_host_permissions"])
            .union(Self.strings(old, ["permissions"]).filter { $0.contains("://") || $0 == "<all_urls>" })
        let oldLines = Set(Self.abilities(permissions: Self.strings(old, ["permissions", "optional_permissions"]), patterns: Array(oldPatterns), id: id))
        abilities = full.abilities.filter { !oldLines.contains($0) }
        limits = full.limits
    }

    private static func strings(_ manifest: [String: Any], _ keys: [String]) -> Set<String> {
        Set(keys.flatMap { manifest[$0] as? [String] ?? [] })
    }

    // MARK: Plain words

    private static func abilities(permissions: Set<String>, patterns: [String], id: String) -> [Line] {
        var lines: [Line] = []
        let hosts = patterns.compactMap(host(of:))
        if patterns.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") || $0.hasPrefix("http://*/") || $0.hasPrefix("https://*/") }) {
            lines.append(Line(symbol: "globe", text: "Read and change what you see on every website"))
        } else if let first = hosts.first {
            let others = Set(hosts).count - 1
            lines.append(Line(symbol: "globe", text: others > 0 ? "Read and change what you see on \(first) and \(others) other site\(others == 1 ? "" : "s")" : "Read and change what you see on \(first)"))
        }
        if permissions.contains("nativeMessaging") {
            lines.append(Line(symbol: "macwindow", text: "Talk to \(appName(for: id)) on your Mac"))
        }
        if permissions.contains("tabs") || permissions.contains("webNavigation") || permissions.contains("history") {
            lines.append(Line(symbol: "clock", text: "See the sites you visit"))
        }
        if permissions.contains("declarativeNetRequest") || permissions.contains("declarativeNetRequestWithHostAccess") {
            lines.append(Line(symbol: "hand.raised", text: "Block content on pages"))
        }
        if permissions.contains("cookies") {
            lines.append(Line(symbol: "lock", text: "Read and change cookies on the sites it can access"))
        }
        if permissions.contains("management") {
            lines.append(Line(symbol: "puzzlepiece.extension", text: "See your other extensions"))
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

    private static func appName(for id: String) -> String {
        switch id {
        case ExtensionStore.onePasswordID: "the 1Password app"
        case "nngceckbapebfimnlniiiahkandclblb": "the Bitwarden app"
        default: "an app"
        }
    }

    /// Permissions WebKit doesn't support, by the feature a person would notice is missing.
    private static let limitNames: [String: String] = [
        "sidePanel": "Side panel",
        "identity": "Signing in with your account",
        "identity.email": "Signing in with your account",
        "notifications": "Notifications",
        "downloads": "Downloads",
        "downloads.open": "Downloads",
        "idle": "Knowing when you’re away",
        "offscreen": "Background audio and clipboard",
        "userScripts": "Your own custom scripts",
        "webRequestBlocking": "Blocking requests the old way",
        "webRequestAuthProvider": "Filling in sign-in dialogs",
        "history": "Your browsing history",
        "bookmarks": "Your bookmarks",
        "topSites": "Your top sites",
        "tabGroups": "Tab groups",
        "fontSettings": "Font settings",
        "tts": "Reading aloud",
        "ttsEngine": "Reading aloud",
        "geolocation": "Your location",
        "clipboardRead": "Reading what you copy",
        "management": "Managing other extensions",
        "privacy": "Privacy settings",
        "proxy": "Proxy settings",
        "debugger": "Debugging pages",
        "pageCapture": "Saving pages",
        "desktopCapture": "Recording your screen",
        "tabCapture": "Recording tabs",
        "system.display": "Display information",
        "power": "Keeping your Mac awake",
    ]

    /// Manifest features with no WebKit equivalent.
    private static let manifestLimits: [(String, String)] = [
        ("side_panel", "Side panel"),
        ("omnibox", "Address bar keyword"),
        ("chrome_url_overrides", "Replacing the new tab page"),
    ]
}

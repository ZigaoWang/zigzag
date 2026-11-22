import Foundation

/// Zigzag's support status for one Chrome API path (namespace, member, event, constant or enum value).
/// `chrome-api.json` lists every path; `compatibility.json` claims the non-default ones. Unclaimed paths are unsupported.
nonisolated enum CompatibilityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    /// WebKit supplies it and matches Chrome's observable contract.
    case native
    /// WebKit supplies it and `webkit-differences.js` corrects it; the claim names the correction.
    case patched
    /// Zigzag's native code answers it; the claim names the handler.
    case bridged
    /// Zigzag reproduces the observable behavior without the Chrome service; the claim names it.
    case emulated
    /// Not available: fails the way Chrome does and gets a line in the install sheet.
    case unsupported
    /// Chrome has removed it; answered only where old extensions still call it.
    case deprecated

    /// Ranking, best first. Only for namespace summaries; claims never inherit through it.
    var strength: Int {
        switch self {
        case .native: return 0
        case .patched: return 1
        case .bridged: return 2
        case .emulated: return 3
        case .deprecated: return 4
        case .unsupported: return 5
        }
    }

    /// The weaker of two, for a namespace summary. Inheritance never uses it.
    static func worst(_ one: CompatibilityStatus, _ other: CompatibilityStatus) -> CompatibilityStatus {
        one.strength >= other.strength ? one : other
    }
}

/// Install sheet status for a manifest permission or key. Separate from API path status: a supported permission can
/// turn on an unsupported member.
nonisolated enum CompatibilityPermissionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    /// Everything the permission turns on works; the sheet has no line for it.
    case supported
    /// Partly works; one sheet line per distinct limit.
    case partial
    /// Nothing works; one sheet line with the reason and group.
    case unsupported
    /// Kept for old extensions; one sheet line.
    case deprecated
}

/// Why a path differs from Chrome. The install sheet groups its text by these; the overlay holds no English.
nonisolated enum CompatibilityReason: String, Codable, Hashable, Sendable {
    /// WebKit has no such API, and Zigzag has not reproduced it.
    case webkitMissing
    /// The API is not implemented yet.
    case notImplemented
    /// A Chrome service; Zigzag doesn't pretend to be Chrome.
    case chromeService
    /// macOS can't do it (notifications, capture surfaces).
    case platform
    /// Zigzag policy, e.g. private windows.
    case policy
    /// Security gate (e.g. developer-only signature) that compatibility doesn't lift.
    case securityGate
    /// A Google channel Chrome has deprecated.
    case deprecatedChannel
    /// Enterprise policy, which Zigzag does not have.
    case enterprise
    /// Chrome removed the member; an old extension may still call it.
    case removed
}

/// One claim: a status and the details it needs.
nonisolated struct CompatibilityClaim: Codable, Sendable {
    var status: CompatibilityStatus
    /// Required for patched, bridged and emulated. `swift:` names an `ExtensionBridge` handler by namespace (`contexts`)
    /// or class (`BridgeContexts`); `js:` names a symbol in `webkit-differences.js` or `ExtensionShims.compatibility`.
    var implementation: String?
    /// Required for unsupported and deprecated.
    var reason: CompatibilityReason?
    /// Required for unsupported and deprecated: the install sheet group, which gives the catalog key.
    var group: String?
    /// Member claims under this path (`storage.local` under `storage`); each overrides the namespace for that member only.
    var members: [String: CompatibilityClaim]?
}

/// Install sheet entry for a manifest permission or key, separate from the API paths it turns on.
nonisolated struct CompatibilityPermission: Codable, Sendable {
    var status: CompatibilityPermissionStatus
    /// Claimed API paths this permission covers; a partial permission gets one line per distinct limit.
    var claims: [String]?
    var reason: CompatibilityReason?
    /// Catalog key for a limit that covers the whole permission.
    var catalog: String?
    var group: String?
    /// Sort order in the sheet.
    var order: Int?
}

/// A group of install sheet lines and their catalog key.
nonisolated struct CompatibilityGroup: Codable, Sendable {
    var catalog: String
    var order: Int?
}

/// Hand-written claims over the generated API list; only non-default paths.
nonisolated struct CompatibilityOverlay: Codable, Sendable {
    var schemaVersion: Int
    var chromeTypes: String
    var groups: [String: CompatibilityGroup]
    var claims: [String: CompatibilityClaim]
    var permissions: [String: CompatibilityPermission]
    var manifest: [String: CompatibilityPermission]

    enum LoadError: LocalizedError {
        case missingResource
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "compatibility.json is missing from the app"
            case .malformed(let reason):
                return "compatibility.json is malformed: \(reason)"
            }
        }
    }

    /// The shipped overlay. `bundle` is the app's or a test's.
    static func load(bundle: Bundle = .main) throws -> CompatibilityOverlay {
        guard let url = bundle.url(forResource: "compatibility", withExtension: "json") else {
            throw LoadError.missingResource
        }
        do {
            return try JSONDecoder().decode(CompatibilityOverlay.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.malformed(error.localizedDescription)
        }
    }
}

/// One install sheet line: a limit, its group and its catalog key.
nonisolated struct CompatibilityLimit: Hashable, Sendable {
    let catalogKey: String?
    let group: String
    let reason: CompatibilityReason
    /// Status the line shows: the permission's own, or partial for a limit inside a partial permission.
    let status: CompatibilityPermissionStatus
    /// Fallback text until the catalog has the key: the permission or manifest key name.
    let source: String

    var text: String { CompatibilityText.text(for: catalogKey, fallback: source) }
}

/// Install sheet text by catalog key. Keys without a localized string show their fallback.
nonisolated enum CompatibilityText {
    static func text(for key: String?, fallback: String) -> String {
        guard let key else { return fallback }
        switch key {
        case "extension.limit.tabGroups":
            return String(localized: "extension.limit.tabGroups", defaultValue: "Tab groups",
                          comment: "A Chrome extension feature Zigzag cannot provide: grouping tabs.")
        case "extension.limit.tabActions":
            return String(localized: "extension.limit.tabActions", defaultValue: "Some tab actions",
                          comment: "A Chrome extension feature Zigzag cannot provide: splitting tabs and other tab actions beyond opening and switching.")
        case "extension.limit.tabHousekeeping":
            return String(localized: "extension.limit.tabHousekeeping", defaultValue: "Discarding and highlighting tabs",
                          comment: "A Chrome extension feature Zigzag cannot provide: discarding tabs to save memory and highlighting a set of tabs.")
        case "extension.limit.windowsPopup":
            return String(localized: "extension.limit.windowsPopup", defaultValue: "Popup windows",
                          comment: "A Chrome extension feature Zigzag limits: extension windows opened as popups.")
        case "extension.limit.runtime":
            return String(localized: "extension.limit.runtime", defaultValue: "Restarting Zigzag",
                          comment: "A Chrome extension feature Zigzag cannot provide: restarting the browser or reading its package folder.")
        case "extension.limit.runtimeContexts":
            return String(localized: "extension.limit.runtimeContexts", defaultValue: "Open pages (background, popup, side panel and offscreen only; no tabs, subframes, developer tools or document IDs)",
                          comment: "A Chrome extension feature Zigzag limits: runtime.getContexts reports background, popup, side panel and offscreen contexts only; tabs, subframes, developer tools and real document IDs are not reported.")
        case "extension.limit.backgroundPage":
            return String(localized: "extension.limit.backgroundPage", defaultValue: "The background page (Manifest V2 only; Manifest V3 pages get “You do not have a background page.”)",
                          comment: "A Chrome extension feature Zigzag limits: runtime.getBackgroundPage answers Manifest V2 only; a Manifest V3 page gets “You do not have a background page.” A Manifest V3 worker keeps WebKit's member, visible rather than absent.")
        case "extension.limit.action":
            return String(localized: "extension.limit.action", defaultValue: "Toolbar button settings",
                          comment: "A Chrome extension feature Zigzag limits: badge text color and toolbar button settings.")
        case "extension.limit.notifications":
            return String(localized: "extension.limit.notifications", defaultValue: "Notifications",
                          comment: "A Chrome extension feature Zigzag limits: notification buttons and settings.")
        case "extension.limit.sidePanel":
            return String(localized: "extension.limit.sidePanel", defaultValue: "Side panel",
                          comment: "A Chrome extension feature Zigzag limits: the side panel's layout and open/close events.")
        case "extension.limit.systemDisplay":
            return String(localized: "extension.limit.systemDisplay", defaultValue: "Display information",
                          comment: "A Chrome extension feature Zigzag limits: changing display settings.")
        case "extension.limit.power":
            return String(localized: "extension.limit.power", defaultValue: "Keeping your Mac awake",
                          comment: "A Chrome extension feature Zigzag limits: reporting activity to keep the Mac awake.")
        case "extension.limit.signIn":
            return String(localized: "extension.limit.signIn", defaultValue: "Signing in with your account",
                          comment: "A Chrome extension feature Zigzag limits: Chrome's own Google account sign-in.")
        case "extension.limit.bookmarks":
            return String(localized: "extension.limit.bookmarks", defaultValue: "Your bookmarks",
                          comment: "A Chrome extension feature Zigzag limits: bookmark import and reorder events.")
        case "extension.limit.downloads":
            return String(localized: "extension.limit.downloads", defaultValue: "Downloads",
                          comment: "A Chrome extension feature Zigzag limits: the download shelf, danger prompts and filename events.")
        case "extension.limit.tabCapture":
            return String(localized: "extension.limit.tabCapture", defaultValue: "Recording tabs",
                          comment: "A Chrome extension feature Zigzag limits: tab video capture; audio is captured.")
        case "extension.limit.tabVideoCapture":
            return String(localized: "extension.limit.tabVideoCapture", defaultValue: "Tab video capture",
                          comment: "A Chrome extension feature Zigzag cannot provide: recording a tab's video; audio capture works.")
        case "extension.limit.cookies":
            return String(localized: "extension.limit.cookies", defaultValue: "Cookie details",
                          comment: "A Chrome extension feature Zigzag limits: cookie partition keys.")
        case "extension.limit.cookiePartitions":
            return String(localized: "extension.limit.cookiePartitions", defaultValue: "Cookie partition details",
                          comment: "A Chrome extension feature Zigzag cannot provide: reading a cookie's partition key.")
        case "extension.limit.hostAccessRequests":
            return String(localized: "extension.limit.hostAccessRequests", defaultValue: "Site access requests",
                          comment: "A Chrome extension feature Zigzag cannot provide: asking for host access at runtime.")
        case "extension.limit.storage":
            return String(localized: "extension.limit.storage", defaultValue: "Stored extension settings",
                          comment: "A Chrome extension feature Zigzag emulates: managed extension storage.")
        case "extension.limit.storageSync":
            return String(localized: "extension.limit.storageSync", defaultValue: "Settings synced between Macs",
                          comment: "A Chrome extension feature Zigzag limits: storage.sync keeps its settings on this Mac instead of syncing them.")
        case "extension.limit.localScripts":
            return String(localized: "extension.limit.localScripts", defaultValue: "Scripts on local files",
                          comment: "A Chrome extension feature Zigzag limits: registered content scripts that name file: pages.")
        case "extension.limit.blockingRules":
            return String(localized: "extension.limit.blockingRules", defaultValue: "Blocking rules",
                          comment: "A Chrome extension feature Zigzag limits: switching individual network rules on and off.")
        case "extension.limit.staticRuleChanges":
            return String(localized: "extension.limit.staticRuleChanges", defaultValue: "Changes to static blocking rules",
                          comment: "A Chrome extension feature Zigzag cannot provide: switching individual static rules on and off with declarativeNetRequest.updateStaticRules.")
        case "extension.limit.matchedRuleDebugging":
            return String(localized: "extension.limit.matchedRuleDebugging", defaultValue: "Matched-rule debugging",
                          comment: "A Chrome extension feature Zigzag cannot provide: seeing which blocking rules matched a request.")
        case "extension.limit.webRequestBlocking":
            return String(localized: "extension.limit.webRequestBlocking", defaultValue: "Blocking requests the old way",
                          comment: "A Chrome extension feature Zigzag cannot provide: blocking web requests with webRequest.")
        case "extension.limit.languageDetection":
            return String(localized: "extension.limit.languageDetection", defaultValue: "Language detection",
                          comment: "A Chrome extension feature Zigzag cannot provide: i18n.detectLanguage.")
        case "extension.limit.legacyExtension":
            return String(localized: "extension.limit.legacyExtension", defaultValue: "Legacy extension APIs",
                          comment: "A Chrome extension feature Chrome removed: the old chrome.extension namespace.")
        case "extension.limit.sessions":
            return String(localized: "extension.limit.sessions", defaultValue: "Closed tabs and sessions",
                          comment: "A Chrome extension feature Zigzag cannot provide: the sessions API.")
        case "extension.limit.search":
            return String(localized: "extension.limit.search", defaultValue: "Search settings",
                          comment: "A Chrome extension feature Zigzag cannot provide: the search API.")
        case "extension.limit.debugger":
            return String(localized: "extension.limit.debugger", defaultValue: "Debugging pages",
                          comment: "A Chrome extension feature Zigzag cannot provide: the debugger API.")
        case "extension.limit.fontSettings":
            return String(localized: "extension.limit.fontSettings", defaultValue: "Font settings",
                          comment: "A Chrome extension feature Zigzag cannot provide: the fontSettings API.")
        case "extension.limit.privacySettings":
            return String(localized: "extension.limit.privacySettings", defaultValue: "Privacy settings",
                          comment: "A Chrome extension feature Zigzag cannot provide: changing the browser's privacy settings.")
        case "extension.limit.management":
            return String(localized: "extension.limit.management", defaultValue: "Managing other extensions",
                          comment: "A Chrome extension feature Zigzag limits: listing and changing other extensions.")
        case "extension.limit.pageCapture":
            return String(localized: "extension.limit.pageCapture", defaultValue: "Saving pages",
                          comment: "A Chrome extension feature Zigzag cannot provide: saving a page as MHTML.")
        case "extension.limit.desktopCapture":
            return String(localized: "extension.limit.desktopCapture", defaultValue: "Recording your screen",
                          comment: "A Chrome extension feature Zigzag cannot provide: the desktopCapture API.")
        case "extension.limit.publicSuffix":
            return String(localized: "extension.limit.publicSuffix", defaultValue: "Domain names",
                          comment: "A Chrome extension feature Zigzag cannot provide: the publicSuffix API.")
        case "extension.limit.devtools":
            return String(localized: "extension.limit.devtools", defaultValue: "Developer tools",
                          comment: "A Chrome extension feature Zigzag cannot provide: extension DevTools panels.")
        case "extension.limit.contentSettings":
            return String(localized: "extension.limit.contentSettings", defaultValue: "Content settings",
                          comment: "A Chrome extension feature Zigzag cannot provide: the contentSettings API.")
        case "extension.limit.readingList":
            return String(localized: "extension.limit.readingList", defaultValue: "Reading list",
                          comment: "A Chrome extension feature Zigzag cannot provide: the readingList API.")
        case "extension.limit.tts":
            return String(localized: "extension.limit.tts", defaultValue: "Reading aloud",
                          comment: "A Chrome extension feature Zigzag limits: extensions that are themselves a text-to-speech engine.")
        case "extension.limit.geolocation":
            return String(localized: "extension.limit.geolocation", defaultValue: "Your location",
                          comment: "A Chrome extension feature Zigzag cannot provide: the geolocation permission.")
        case "extension.limit.clipboardRead":
            return String(localized: "extension.limit.clipboardRead", defaultValue: "Reading what you copy",
                          comment: "A Chrome extension feature Zigzag cannot provide: reading the clipboard.")
        case "extension.limit.proxyScripts":
            return String(localized: "extension.limit.proxyScripts", defaultValue: "Proxy scripts (PAC)",
                          comment: "A Chrome extension feature Zigzag cannot provide: proxy auto-config scripts, which choose a proxy for each site.")
        case "extension.limit.firefoxProxy":
            return String(localized: "extension.limit.firefoxProxy", defaultValue: "Setting a proxy (Firefox’s proxy API)",
                          comment: "A Firefox extension feature Zigzag cannot provide: Firefox's own proxy API, which VPN and proxy extensions built for Firefox use to send pages through their servers.")
        case "extension.limit.deprecatedChannel":
            return String(localized: "extension.limit.deprecatedChannel", defaultValue: "Deprecated Google APIs",
                          comment: "A Chrome extension feature Chrome removed: its old Google messaging channels.")
        default:
            return fallback
        }
    }
}

/// A name an implementation may reference: a bridge handler (`swift:history`) or a name the correction scripts define
/// (`js:setMember`, `js:cookies.onChanged`). Both are read from the code. `emulated` claims name compatibility shim
/// members (`js:getSelf`, `js:managed`).
nonisolated struct CompatibilityImplementations: Sendable {
    /// Bridge handler names: each namespace and each handler class name.
    let handlers: Set<String>
    /// Source of `webkit-differences.js` and the compatibility shim.
    let script: String
    /// Identifiers the scripts define, to check `js:` names against.
    private let symbols: Set<String>

    init(handlers: Set<String>, script: String) {
        self.handlers = handlers
        self.script = script
        symbols = Self.identifiers(in: script)
    }

    /// The shipped handlers, `webkit-differences.js` and compatibility shim. The shim covers members WebKit lacks but
    /// Chrome still lists (`management.getSelf`, `storage.managed`), so `emulated` claims name it.
    @MainActor
    static func shipped(bundle: Bundle = .main) -> CompatibilityImplementations {
        let differences = bundle.url(forResource: "webkit-differences", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return CompatibilityImplementations(handlers: ExtensionBridge.handlerNames
                                                .union(ExtensionBridge.handlerTypeNames),
                                            script: differences + "\n" + ExtensionShims.compatibility)
    }

    /// Whether an implementation name exists. Dotted `js:` names are checked part by part (`cookies.onChanged`).
    func implements(_ implementation: String) -> Bool {
        if implementation.hasPrefix("swift:") {
            return handlers.contains(String(implementation.dropFirst("swift:".count)))
        }
        if implementation.hasPrefix("js:") {
            let parts = implementation.dropFirst("js:".count).split(separator: ".", omittingEmptySubsequences: false)
            return !parts.isEmpty && parts.allSatisfy { symbols.contains(String($0)) }
        }
        return false
    }

    /// Identifiers in the script's code. Comments, strings and regexes are skipped so stale mentions don't pass the check.
    private static func identifiers(in script: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).inverted
        let names = code(in: script).components(separatedBy: separators).filter { name in
            guard let first = name.first else { return false }
            return !first.isNumber
        }
        return Set(names)
    }

    /// The script with comments, strings and regex bodies blanked out.
    private static func code(in script: String) -> String {
        let characters = Array(script)
        var code: [Character] = []
        var index = 0
        var previous: Character?
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "/", next == "/" {
                index += 2
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "/", next == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                code.append(" ")
                continue
            }
            if character == "'" || character == "\"" || character == "`" {
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    index += 1
                    if current == "\\" {
                        index += 1
                        continue
                    }
                    if current == character { break }
                    // Unclosed quote on its line: probably a misread division or regex; stop.
                    if character != "`", current == "\n" { break }
                }
                code.append(" ")
                continue
            }
            if character == "/", startsRegex(after: previous) {
                index += 1
                var inClass = false
                while index < characters.count {
                    let current = characters[index]
                    index += 1
                    if current == "\\" {
                        index += 1
                        continue
                    }
                    if current == "[" { inClass = true } else if current == "]" { inClass = false }
                    else if current == "/", !inClass { break }
                    else if current == "\n" { break }
                }
                code.append(" ")
                continue
            }
            code.append(character)
            if !character.isWhitespace { previous = character }
            index += 1
        }
        return String(code)
    }

    /// Whether `/` starts a regex: after a name, number or closing bracket it's division.
    private static func startsRegex(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return "([{=,:;!&|?+-*%^~<>".contains(previous)
    }
}

/// Overlay problems: claims on paths Chrome lacks, duplicate claims, missing required fields, implementations that
/// don't exist, groups with no catalog.
nonisolated enum CompatibilityValidator {
    /// Problems in stable order; empty when the overlay is valid.
    static func diagnostics(overlay: CompatibilityOverlay, universe: ChromeUniverse,
                            implementations: CompatibilityImplementations) -> [String] {
        var diagnostics: [String] = []
        var claimed: [String: CompatibilityClaim] = [:]
        walk(overlay.claims, prefix: "", into: &claimed, universe: universe, overlay: overlay,
             implementations: implementations, diagnostics: &diagnostics)
        let registry = CompatibilityRegistry(overlay: overlay)
        check(overlay.permissions, at: "permissions", in: overlay, universe: universe,
              registry: registry, diagnostics: &diagnostics)
        check(overlay.manifest, at: "manifest", in: overlay, universe: universe,
              registry: registry, diagnostics: &diagnostics)
        return diagnostics
    }

    private static func walk(_ claims: [String: CompatibilityClaim], prefix: String,
                             into claimed: inout [String: CompatibilityClaim], universe: ChromeUniverse,
                             overlay: CompatibilityOverlay, implementations: CompatibilityImplementations,
                             diagnostics: inout [String]) {
        for (name, claim) in claims.sorted(by: { $0.key < $1.key }) {
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            if claimed[path] != nil {
                diagnostics.append("\(path) is claimed twice")
            } else {
                claimed[path] = claim
            }
            check(claim, at: path, universe: universe, overlay: overlay,
                  implementations: implementations, diagnostics: &diagnostics)
            walk(claim.members ?? [:], prefix: path, into: &claimed, universe: universe, overlay: overlay,
                 implementations: implementations, diagnostics: &diagnostics)
        }
    }

    private static func check(_ claim: CompatibilityClaim, at path: String, universe: ChromeUniverse,
                              overlay: CompatibilityOverlay, implementations: CompatibilityImplementations,
                              diagnostics: inout [String]) {
        if !universe.contains(path) {
            diagnostics.append("\(path) is not in Chrome's API")
        }
        switch claim.status {
        case .patched, .bridged, .emulated:
            if let implementation = claim.implementation, !implementation.isEmpty {
                if !implementations.implements(implementation) {
                    diagnostics.append("\(path) names the implementation \(implementation), which does not exist")
                }
            } else {
                diagnostics.append("\(path) is \(claim.status.rawValue) but names no implementation")
            }
        case .unsupported, .deprecated:
            if claim.reason == nil {
                diagnostics.append("\(path) is \(claim.status.rawValue) but gives no reason")
            }
            if claim.group == nil {
                diagnostics.append("\(path) is \(claim.status.rawValue) but names no group")
            }
        case .native:
            break
        }
        if let group = claim.group, !hasCatalog(group, in: overlay) {
            diagnostics.append("\(path) names the group \(group), which has no catalog key")
        }
    }

    /// Checks a permission or key entry. Partial needs claims or its own catalog; unsupported and deprecated need a reason
    /// and group. Claims resolve through the registry like the sheet, so a namespace claim covers its members, and a
    /// member's own limit counts even if the member is unsupported.
    private static func check(_ rows: [String: CompatibilityPermission], at section: String,
                              in overlay: CompatibilityOverlay, universe: ChromeUniverse,
                              registry: CompatibilityRegistry, diagnostics: inout [String]) {
        for (name, row) in rows.sorted(by: { $0.key < $1.key }) {
            let path = "\(section).\(name)"
            if let group = row.group, !hasCatalog(group, in: overlay) {
                diagnostics.append("\(path) names the group \(group), which has no catalog key")
            }
            switch row.status {
            case .supported:
                break
            case .partial:
                let named = row.claims ?? []
                if named.isEmpty && row.catalog == nil {
                    diagnostics.append("\(path) is partial but names no claims and has no catalog")
                }
                for claim in named {
                    guard universe.contains(claim) else {
                        diagnostics.append("\(path) names the claim \(claim), which Chrome's API does not have")
                        continue
                    }
                    if registry.claim(for: claim) == nil {
                        diagnostics.append("\(path) names the claim \(claim), which the overlay does not resolve")
                    }
                }
            case .unsupported, .deprecated:
                if row.reason == nil {
                    diagnostics.append("\(path) is \(row.status.rawValue) but gives no reason")
                }
                if row.group == nil {
                    diagnostics.append("\(path) is \(row.status.rawValue) but names no group")
                }
            }
        }
    }

    private static func hasCatalog(_ group: String, in overlay: CompatibilityOverlay) -> Bool {
        guard let entry = overlay.groups[group] else { return false }
        return !entry.catalog.isEmpty
    }
}

/// Claims resolved per path: the deepest claim on or above it, with member overrides winning for themselves only.
nonisolated struct CompatibilityRegistry: Sendable {
    /// All claims by canonical path, nested members flattened.
    private let claims: [String: CompatibilityClaim]

    init(overlay: CompatibilityOverlay) {
        var paths: [String: CompatibilityClaim] = [:]
        Self.flatten(overlay.claims, prefix: "", into: &paths)
        claims = paths
    }

    /// Every path the overlay claims.
    var claimedPaths: Set<String> { Set(claims.keys) }

    /// The claim for `path`: the deepest one on or above it, member overrides first. Nil when none covers it (unsupported).
    func claim(for path: String) -> CompatibilityClaim? {
        let above = claims.keys.filter { $0 == path || path.hasPrefix($0 + ".") }.sorted { $0.count < $1.count }
        guard !above.isEmpty else { return nil }
        var resolved = CompatibilityClaim(status: .unsupported)
        for ancestor in above {
            guard let claim = claims[ancestor] else { continue }
            resolved.status = claim.status
            resolved.implementation = claim.implementation ?? resolved.implementation
            resolved.reason = claim.reason ?? resolved.reason
            resolved.group = claim.group ?? resolved.group
        }
        return resolved
    }

    /// Weakest status on or under `path`, for display only. Nothing inherits from it.
    func status(of path: String) -> CompatibilityStatus {
        if let own = claims[path] {
            let below = claims.keys.filter { $0.hasPrefix(path + ".") }
            return below.reduce(own.status) { CompatibilityStatus.worst($0, claims[$1]?.status ?? .unsupported) }
        }
        guard let above = claims.keys.filter({ path.hasPrefix($0 + ".") }).max(by: { $0.count < $1.count }),
              let claim = claims[above] else { return .unsupported }
        return claim.status
    }

    private static func flatten(_ claims: [String: CompatibilityClaim], prefix: String,
                                into paths: inout [String: CompatibilityClaim]) {
        for (name, claim) in claims {
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            var flattened = claim
            flattened.members = nil
            paths[path] = flattened
            flatten(claim.members ?? [:], prefix: path, into: &paths)
        }
    }
}

/// The shipped claims, read once, and the install sheet lines they produce.
/// Report-only: nothing reads it to grant or drop permissions.
nonisolated struct ExtensionCompatibility {
    /// Nil when there is none, as in tests.
    static let shared = ExtensionCompatibility(overlay: try? CompatibilityOverlay.load(),
                                               universe: try? ChromeUniverse.load())

    let overlay: CompatibilityOverlay?
    let universe: ChromeUniverse?
    /// The resolved claims for a path, if there is an overlay.
    let registry: CompatibilityRegistry?

    init(overlay: CompatibilityOverlay?, universe: ChromeUniverse? = nil) {
        self.overlay = overlay
        self.universe = universe
        registry = overlay.map { CompatibilityRegistry(overlay: $0) }
    }

    /// Install sheet lines for these permissions and manifest keys, one per catalog key, in overlay order. Supported,
    /// partial and unclaimed entries get no line.
    func limits(forPermissions permissions: Set<String>, manifestKeys: Set<String>) -> [CompatibilityLimit] {
        guard let overlay else { return [] }
        var lines: [(order: Int, source: String, limit: CompatibilityLimit)] = []

        func add(_ row: CompatibilityPermission, named name: String) {
            switch row.status {
            case .supported, .partial:
                // Partial permissions get no line for now; their narrower claims are kept for a later, finer sheet.
                return
            case .unsupported, .deprecated:
                let group = row.group ?? name
                let catalog = row.catalog ?? overlay.groups[group]?.catalog
                let order = row.order ?? overlay.groups[group]?.order ?? 0
                lines.append((order, name, CompatibilityLimit(catalogKey: catalog, group: group,
                                                              reason: row.reason ?? .notImplemented,
                                                              status: row.status, source: name)))
            }
        }

        for name in permissions.sorted() {
            guard let row = overlay.permissions[name] else { continue }
            add(row, named: name)
        }
        for name in manifestKeys.sorted() {
            guard let row = overlay.manifest[name] else { continue }
            add(row, named: name)
        }
        // One line per catalog key; several entries can share the same text.
        var seen: Set<String> = []
        return lines.sorted { ($0.order, $0.source) < ($1.order, $1.source) }
            .map(\.limit)
            .filter { seen.insert($0.catalogKey ?? "group:\($0.group)").inserted }
    }
}

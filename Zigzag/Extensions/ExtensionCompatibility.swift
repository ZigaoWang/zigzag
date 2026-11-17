import Foundation

/// What Zigzag promises about one path in Chrome's API: a namespace (`storage`), a member (`storage.local.get`), an
/// event, a constant or an enum value.
///
/// `chrome-api.json` is the universe of paths; `compatibility.json` claims the ones whose answer is not the default.
/// Anything the universe lists and the overlay does not claim is unsupported, so the overlay only records what
/// Zigzag reaches.
nonisolated enum CompatibilityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    /// WebKit supplies it and matches Chrome's observable contract.
    case native
    /// WebKit supplies it and `webkit-differences.js` corrects it; the claim names the correction.
    case patched
    /// Zigzag's native code answers it; the claim names the handler.
    case bridged
    /// Zigzag reproduces the observable behaviour without the Chrome service; the claim names it.
    case emulated
    /// Zigzag cannot answer it: a loud, Chrome-shaped failure and a line in the install sheet.
    case unsupported
    /// Chrome has removed it; answered only where old extensions still call it.
    case deprecated

    /// How much of Chrome's contract the status keeps, best first. Used only to summarize a namespace for a person;
    /// a claim never inherits through this.
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

/// What the install sheet says about a manifest permission or key. This is not an API path's status: a permission can
/// be supported while one member it turns on is not, so its answer is the sheet's own four-value axis.
nonisolated enum CompatibilityPermissionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    /// Everything the permission turns on works; the sheet has no line for it.
    case supported
    /// Some of it works; the sheet has one line per distinct limit the claims name.
    case partial
    /// Nothing it turns on works; the sheet has one line with the reason and group.
    case unsupported
    /// Chrome still answers it for old extensions; the sheet says so in one line.
    case deprecated
}

/// Why a path is not what an extension would have in Chrome. The install sheet groups its words by these, so the
/// overlay never carries English prose itself.
nonisolated enum CompatibilityReason: String, Codable, Hashable, Sendable {
    /// WebKit has no such API, and Zigzag has not reproduced it.
    case webkitMissing
    /// The API is not implemented yet.
    case notImplemented
    /// The feature is a Chrome service, and Zigzag does not pretend to be Chrome.
    case chromeService
    /// The platform (macOS, its notifications, its capture surfaces) cannot show or do it.
    case platform
    /// Zigzag's own policy says no, as with private windows.
    case policy
    /// A security gate, such as a developer-only signature, that compatibility does not lift.
    case securityGate
    /// A Google channel Chrome has deprecated.
    case deprecatedChannel
    /// Enterprise policy, which Zigzag does not have.
    case enterprise
    /// Chrome removed the member; an old extension may still call it.
    case removed
}

/// One claim: a status, and whatever that status needs to say why and how.
nonisolated struct CompatibilityClaim: Codable, Sendable {
    var status: CompatibilityStatus
    /// Required for patched, bridged and emulated: `swift:` names an `ExtensionBridge` handler by its namespace
    /// (`contexts`) or its class (`BridgeContexts`), `js:` a symbol in `webkit-differences.js` or the compatibility
    /// shim (`ExtensionShims.compatibility`).
    var implementation: String?
    /// Required for unsupported and deprecated.
    var reason: CompatibilityReason?
    /// Required for unsupported and deprecated: the install sheet's group, and through it its catalog key.
    var group: String?
    /// Claims for members beneath this path, as `storage.local` beneath `storage`; each replaces the namespace's
    /// answer for that member alone.
    var members: [String: CompatibilityClaim]?
}

/// What the install sheet says about a manifest permission or key, separate from the API paths it turns on.
nonisolated struct CompatibilityPermission: Codable, Sendable {
    var status: CompatibilityPermissionStatus
    /// The claimed API paths this permission is about, so a partial permission shows one line per distinct limit.
    var claims: [String]?
    var reason: CompatibilityReason?
    /// The catalog key of the limit that covers the whole permission, where one line does.
    var catalog: String?
    var group: String?
    /// Where the line goes in the sheet.
    var order: Int?
}

/// A group of install-sheet lines, and the catalog key they are written under.
nonisolated struct CompatibilityGroup: Codable, Sendable {
    var catalog: String
    var order: Int?
}

/// The hand-maintained claims over the generated universe: only the paths whose status is not the default.
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

    /// The overlay as the app ships it. `bundle` is the app's, or a test's, own bundle.
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

/// One line in the install sheet: a limit, the group it belongs to and the catalog key its words live under.
nonisolated struct CompatibilityLimit: Hashable, Sendable {
    let catalogKey: String?
    let group: String
    let reason: CompatibilityReason
    /// The permission answer the line shows: the permission's own status for a whole-permission line, or partial for
    /// the limit a partial row names.
    let status: CompatibilityPermissionStatus
    /// What the line falls back to until the catalog has text for its key: the permission or manifest key.
    let source: String

    var text: String { CompatibilityText.text(for: catalogKey, fallback: source) }
}

/// The install sheet's words, by catalog key. The keys are semantic, so a later key's text does not live in the
/// overlay; until a key has a localized string its fallback is shown.
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
                          comment: "A Chrome extension feature Zigzag limits: runtime.getBackgroundPage answers Manifest V2 only; a Manifest V3 page gets “You do not have a background page.” and a Manifest V3 worker has no member.")
        case "extension.limit.action":
            return String(localized: "extension.limit.action", defaultValue: "Toolbar button settings",
                          comment: "A Chrome extension feature Zigzag limits: badge text colour and toolbar button settings.")
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
        case "extension.limit.addressBarKeyword":
            return String(localized: "extension.limit.addressBarKeyword", defaultValue: "Address bar keyword",
                          comment: "A Chrome extension feature Zigzag cannot provide: an omnibox keyword.")
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
        case "extension.limit.deprecatedChannel":
            return String(localized: "extension.limit.deprecatedChannel", defaultValue: "Deprecated Google APIs",
                          comment: "A Chrome extension feature Chrome removed: its old Google messaging channels.")
        default:
            return fallback
        }
    }
}

/// What an implementation may name: a handler the bridge answers (`swift:history`), or a name the corrections
/// scripts write (`js:setMember`, `js:cookies.onChanged`). Both are read from the code that would do the work, never
/// listed a second time here. `emulated` claims name the compatibility shim's members (`js:getSelf`,
/// `js:managed`), which is where an emulation with no Chrome service lives.
nonisolated struct CompatibilityImplementations: Sendable {
    /// The bridge's handler names: each namespace an extension calls, and each handler class's own name.
    let handlers: Set<String>
    /// The corrections scripts' own source: `webkit-differences.js` and the compatibility shim.
    let script: String
    /// Every identifier the script writes, so a `js:` name is checked against what is there.
    private let symbols: Set<String>

    init(handlers: Set<String>, script: String) {
        self.handlers = handlers
        self.script = script
        symbols = Self.identifiers(in: script)
    }

    /// The app's own: the bridge's handlers, `webkit-differences.js` and the compatibility shim as they ship. The
    /// shim answers the few members WebKit has no counterpart for but Chrome still describes (`management.getSelf`,
    /// `storage.managed`), so an `emulated` claim names it rather than a correction it never wrote.
    @MainActor
    static func shipped(bundle: Bundle = .main) -> CompatibilityImplementations {
        let differences = bundle.url(forResource: "webkit-differences", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return CompatibilityImplementations(handlers: ExtensionBridge.handlerNames
                                                .union(ExtensionBridge.handlerTypeNames),
                                            script: differences + "\n" + ExtensionShims.compatibility)
    }

    /// Whether an implementation names something that exists. A dotted `js:` name is checked part by part, as in
    /// `cookies.onChanged`, because the corrections script names the namespace and the member separately.
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

    /// Every identifier the script's code writes. Comments, strings and regular expressions are left out: a name a
    /// comment mentions is not a correction, and a renamed one would otherwise keep passing through a stale line.
    private static func identifiers(in script: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).inverted
        let names = code(in: script).components(separatedBy: separators).filter { name in
            guard let first = name.first else { return false }
            return !first.isNumber
        }
        return Set(names)
    }

    /// The script with its comments, string literals and regular-expression bodies blanked out, so only code is read.
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
                    // A quote that never closes on its line is a division or a regex seen wrong; stop there.
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

    /// Whether a `/` here starts a regular expression rather than a division. After a name, a number or a closing
    /// bracket it divides; after an operator or punctuation it opens a regular expression.
    private static func startsRegex(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return "([{=,:;!&|?+-*%^~<>".contains(previous)
    }
}

/// Everything wrong with an overlay against the universe and the code it names: a claim on a member Chrome does not
/// have, the same path claimed twice, a status missing what it needs, an implementation nobody wrote, or a group with
/// no catalog.
nonisolated enum CompatibilityValidator {
    /// The problems, in a stable order; empty when the overlay can be believed.
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

    /// A permission or manifest key's four-value answer, and what each value needs: a partial one either names the
    /// claims it turns into lines or carries its own resolving catalog, and an unsupported or deprecated one says why
    /// and where its line belongs. A named claim is read the way the install sheet reads it, through the registry, so
    /// a member covered by its namespace is enough, and a member's own limit is named directly even when the member
    /// answers unsupported: that is the gap the row exists to state.
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

/// The claims as they apply to one path: the deepest claim on it or above it, with any member override on the way.
/// A namespace claim is the default for the members it does not override; a member override wins for itself alone.
nonisolated struct CompatibilityRegistry: Sendable {
    /// Every claim the overlay makes, by canonical path, with the nested members flattened away.
    private let claims: [String: CompatibilityClaim]

    init(overlay: CompatibilityOverlay) {
        var paths: [String: CompatibilityClaim] = [:]
        Self.flatten(overlay.claims, prefix: "", into: &paths)
        claims = paths
    }

    /// Every path the overlay claims.
    var claimedPaths: Set<String> { Set(claims.keys) }

    /// The claim that applies to `path`: the deepest claim on it or above it, with any member overrides on the way
    /// taking precedence. A namespace keeps its declared answer for members it does not override. Nil where no
    /// claim covers the path, when the universe's default of unsupported stands.
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

    /// A presentation summary, not the claim anything inherits: the weakest declared status on or under `path`.
    /// The install sheet reads `claim(for:)`, and no member takes its answer from here.
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

/// The app's claims over the generated universe, read once, and the install sheet's lines that follow from them.
///
/// The overlay is report-only: nothing here grants, widens or drops a permission, and nothing else reads it to decide
/// what an extension may do.
nonisolated struct ExtensionCompatibility {
    /// The overlay the app ships. Nil where there is none yet, as in a test or a build before the claims land.
    static let shared = ExtensionCompatibility(overlay: try? CompatibilityOverlay.load(),
                                               universe: try? ChromeUniverse.load())

    let overlay: CompatibilityOverlay?
    let universe: ChromeUniverse?
    /// The claims as they apply to a path, when there is an overlay.
    let registry: CompatibilityRegistry?

    init(overlay: CompatibilityOverlay?, universe: ChromeUniverse? = nil) {
        self.overlay = overlay
        self.universe = universe
        registry = overlay.map { CompatibilityRegistry(overlay: $0) }
    }

    /// The install sheet's lines for an extension asking for these permissions and manifest keys: one per distinct
    /// catalog key, in the overlay's order. A supported permission or key has no line, and one the overlay does not
    /// mention has none either.
    func limits(forPermissions permissions: Set<String>, manifestKeys: Set<String>) -> [CompatibilityLimit] {
        guard let overlay, let registry else { return [] }
        var lines: [(order: Int, source: String, limit: CompatibilityLimit)] = []

        func add(_ row: CompatibilityPermission, named name: String) {
            switch row.status {
            case .supported:
                return
            case .partial:
                if let catalog = row.catalog {
                    let group = row.group ?? name
                    let order = row.order ?? overlay.groups[group]?.order ?? 0
                    lines.append((order, name, CompatibilityLimit(catalogKey: catalog, group: group,
                                                                  reason: row.reason ?? .notImplemented,
                                                                  status: .partial, source: name)))
                }
                for path in row.claims ?? [] {
                    guard let claim = registry.claim(for: path), claim.status != .native,
                          let group = claim.group, let entry = overlay.groups[group] else { continue }
                    let order = row.order ?? entry.order ?? 0
                    // The row is partial, so its line is a caveat about this permission however the member itself is
                    // answered; an unsupported member names the exact gap rather than the whole namespace.
                    lines.append((order, path, CompatibilityLimit(catalogKey: entry.catalog, group: group,
                                                                  reason: claim.reason ?? row.reason ?? .notImplemented,
                                                                  status: .partial, source: path)))
                }
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
        // One line per catalog key: two permissions, or a permission and a claim, may name the same text.
        var seen: Set<String> = []
        return lines.sorted { ($0.order, $0.source) < ($1.order, $1.source) }
            .map(\.limit)
            .filter { seen.insert($0.catalogKey ?? "group:\($0.group)").inserted }
    }
}

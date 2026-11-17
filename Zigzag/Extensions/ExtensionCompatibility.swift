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

    /// How much of Chrome's contract the status keeps, best first. A namespace is never presented as better than its
    /// worst member, so the largest strength under it is the one it shows.
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

    /// The weaker of two: what a namespace shows when one member is unsupported.
    static func worst(_ one: CompatibilityStatus, _ other: CompatibilityStatus) -> CompatibilityStatus {
        one.strength >= other.strength ? one : other
    }
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
    /// Required for patched, bridged and emulated: `swift:` names an `ExtensionBridge` handler, `js:` a symbol in
    /// `webkit-differences.js`.
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
    var status: CompatibilityStatus
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
    let status: CompatibilityStatus
    /// What the line falls back to until the catalog has text for its key: the permission or manifest key.
    let source: String

    var text: String { CompatibilityText.text(for: catalogKey, fallback: source) }
}

/// The install sheet's words, by catalog key. The keys are semantic, so a later key's text does not live in the
/// overlay; until a key has a localized string its fallback is shown.
nonisolated enum CompatibilityText {
    static func text(for key: String?, fallback: String) -> String {
        guard key != nil else { return fallback }
        return fallback
    }
}

/// What an implementation may name: a handler the bridge answers (`swift:history`), or a name the corrections
/// script writes (`js:setMember`, `js:cookies.onChanged`). Both are read from the code that would do the work, never
/// listed a second time here.
nonisolated struct CompatibilityImplementations: Sendable {
    /// The bridge's handler names, by the namespace an extension calls.
    let handlers: Set<String>
    /// The corrections script's own source.
    let script: String
    /// Every identifier the script writes, so a `js:` name is checked against what is there.
    private let symbols: Set<String>

    init(handlers: Set<String>, script: String) {
        self.handlers = handlers
        self.script = script
        symbols = Self.identifiers(in: script)
    }

    /// The app's own: the bridge's handlers and `webkit-differences.js` as it ships.
    @MainActor
    static func shipped(bundle: Bundle = .main) -> CompatibilityImplementations {
        let script = bundle.url(forResource: "webkit-differences", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return CompatibilityImplementations(handlers: ExtensionBridge.handlerNames, script: script)
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

    /// JavaScript identifiers are letters, digits, `_` and `$`.
    private static func identifiers(in script: String) -> Set<String> {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).inverted
        let names = script.components(separatedBy: separators).filter { name in
            guard let first = name.first else { return false }
            return !first.isNumber
        }
        return Set(names)
    }
}

/// Everything wrong with an overlay against the universe and the code it names: a claim on a member Chrome does not
/// have, the same path claimed twice, a status missing what it needs, an implementation nobody wrote, a group with
/// no catalog, or a namespace that presents better than its worst member.
nonisolated enum CompatibilityValidator {
    /// The problems, in a stable order; empty when the overlay can be believed.
    static func diagnostics(overlay: CompatibilityOverlay, universe: ChromeUniverse,
                            implementations: CompatibilityImplementations) -> [String] {
        var diagnostics: [String] = []
        var claimed: [String: CompatibilityClaim] = [:]
        walk(overlay.claims, prefix: "", into: &claimed, universe: universe, overlay: overlay,
             implementations: implementations, diagnostics: &diagnostics)
        for path in claimed.keys.sorted() {
            guard let claim = claimed[path] else { continue }
            checkNamespace(path, claim, claims: claimed, diagnostics: &diagnostics)
        }
        check(overlay.permissions, at: "permissions", in: overlay, diagnostics: &diagnostics)
        check(overlay.manifest, at: "manifest", in: overlay, diagnostics: &diagnostics)
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

    /// A namespace may only present itself as good as its worst claimed member, or its install-sheet line would say
    /// more works than does.
    private static func checkNamespace(_ path: String, _ claim: CompatibilityClaim,
                                       claims: [String: CompatibilityClaim], diagnostics: inout [String]) {
        let members = claims.keys.filter { $0.hasPrefix(path + ".") }.compactMap { member -> (String, CompatibilityStatus)? in
            claims[member].map { (member, $0.status) }
        }
        guard let worst = members.max(by: { $0.1.strength < $1.1.strength }),
              claim.status.strength < worst.1.strength else { return }
        diagnostics.append("\(path) is \(claim.status.rawValue), better than its member \(worst.0) (\(worst.1.rawValue))")
    }

    private static func check(_ rows: [String: CompatibilityPermission], at section: String,
                              in overlay: CompatibilityOverlay, diagnostics: inout [String]) {
        for (name, row) in rows.sorted(by: { $0.key < $1.key }) {
            if let group = row.group, !hasCatalog(group, in: overlay) {
                diagnostics.append("\(section).\(name) names the group \(group), which has no catalog key")
            }
        }
    }

    private static func hasCatalog(_ group: String, in overlay: CompatibilityOverlay) -> Bool {
        guard let entry = overlay.groups[group] else { return false }
        return !entry.catalog.isEmpty
    }
}

/// The claims as they apply to one path: its own claim, the namespace claims above it, and every member override on
/// the way. A namespace is presented as no better than its worst member.
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
    /// taking precedence. Nil where no claim covers it, when the universe's default of unsupported stands.
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
        resolved.status = status(of: path)
        return resolved
    }

    /// What the overlay presents for `path`. A claimed namespace shows its worst member; a member without a claim
    /// of its own keeps its namespace's answer.
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
    /// catalog key, in the overlay's order. A permission or key the overlay does not limit has no line.
    func limits(forPermissions permissions: Set<String>, manifestKeys: Set<String>) -> [CompatibilityLimit] {
        guard let overlay, let registry else { return [] }
        var lines: [(order: Int, source: String, limit: CompatibilityLimit)] = []

        func add(_ row: CompatibilityPermission, named name: String) {
            if let catalog = row.catalog {
                let group = row.group ?? name
                let order = row.order ?? overlay.groups[group]?.order ?? 0
                lines.append((order, name, CompatibilityLimit(catalogKey: catalog, group: group,
                                                              reason: row.reason ?? .notImplemented,
                                                              status: row.status, source: name)))
            }
            for path in row.claims ?? [] {
                guard let claim = registry.claim(for: path), claim.status != .native,
                      let group = claim.group, let entry = overlay.groups[group] else { continue }
                let order = row.order ?? entry.order ?? 0
                lines.append((order, path, CompatibilityLimit(catalogKey: entry.catalog, group: group,
                                                              reason: claim.reason ?? row.reason ?? .notImplemented,
                                                              status: claim.status, source: path)))
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
        var seen: Set<CompatibilityLimit> = []
        return lines.sorted { ($0.order, $0.source) < ($1.order, $1.source) }
            .map(\.limit)
            .filter { seen.insert($0).inserted }
    }
}

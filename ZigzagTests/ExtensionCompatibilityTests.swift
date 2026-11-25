import Foundation
import Testing
@testable import Zigzag

/// Claim overlay over chrome-api.json: the validator and the registry. Fixtures are inline JSON.
struct ExtensionCompatibilityTests {
    /// Handler names and the corrections script, without the app bundle, so the overlay can't vouch for itself.
    private var implementations: CompatibilityImplementations {
        CompatibilityImplementations(handlers: ["history", "runtime", "storage"], script: """
        const cookies = api.cookies;
        const setMember = (path, key, value) => {};
        api.cookies.onChanged.addListener((info) => info);
        """)
    }

    private func universe() throws -> ChromeUniverse {
        try ChromeUniverse.load(bundle: .main)
    }

    private func overlay(_ json: String) throws -> CompatibilityOverlay {
        try JSONDecoder().decode(CompatibilityOverlay.self, from: Data(json.utf8))
    }

    /// An overlay with only the given parts; the rest empty.
    private func overlay(claims: String, groups: String = "{}", permissions: String = "{}",
                         manifest: String = "{}") throws -> CompatibilityOverlay {
        try overlay("""
        {"schemaVersion": 1, "chromeTypes": "0.1.464", "groups": \(groups), "claims": \(claims),
         "permissions": \(permissions), "manifest": \(manifest)}
        """)
    }

    private func diagnostics(claims: String, groups: String = "{}", permissions: String = "{}",
                             manifest: String = "{}") throws -> [String] {
        CompatibilityValidator.diagnostics(overlay: try overlay(claims: claims, groups: groups,
                                                                permissions: permissions, manifest: manifest),
                                           universe: try universe(), implementations: implementations)
    }

    // MARK: The validator

    @Test func everyClaimNamesAMemberOfTheGeneratedUniverse() throws {
        let known = try overlay(claims: """
        {"storage": {"status": "native", "members": {
            "local": {"status": "native", "members": {"get": {"status": "native"}}}
        }},
         "tabs": {"status": "native"}}
        """)
        #expect(CompatibilityValidator.diagnostics(overlay: known, universe: try universe(),
                                                   implementations: implementations).isEmpty)

        let invented = try overlay(claims: """
        {"storage": {"status": "native", "members": {
            "local": {"status": "native", "members": {"erase": {"status": "native"}}}
        }}}
        """)
        let problems = CompatibilityValidator.diagnostics(overlay: invented, universe: try universe(),
                                                          implementations: implementations)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("storage.local.erase") == true)
    }

    @Test func noClaimIsMadeTwice() throws {
        // One canonical path reached through members and as its own claim.
        let problems = try diagnostics(claims: """
        {"storage": {"status": "native", "members": {"local": {"status": "native"}}},
         "storage.local": {"status": "native"}}
        """)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("storage.local") == true)
        #expect(problems.first?.contains("twice") == true)
    }

    @Test func claimsCarryTheFieldsTheirStatusNeeds() throws {
        let problems = try diagnostics(claims: """
        {"tabs": {"status": "bridged"},
         "windows": {"status": "unsupported"},
         "cookies": {"status": "unsupported", "reason": "webkitMissing"},
         "proxy": {"status": "deprecated", "reason": "removed", "group": "unwritten"},
         "history": {"status": "patched", "implementation": "swift:history"}}
        """)
        #expect(problems.contains { $0.contains("tabs") && $0.contains("implementation") })
        #expect(problems.contains { $0.contains("windows") && $0.contains("reason") })
        #expect(problems.contains { $0.contains("windows") && $0.contains("group") })
        #expect(problems.contains { $0.contains("cookies") && $0.contains("group") })
        #expect(problems.contains { $0.contains("proxy") && $0.contains("unwritten") })
        #expect(problems.count == 5)
    }

    @Test func aPermissionRowHasItsOwnFourStatuses() throws {
        let rows = try JSONDecoder().decode([String: CompatibilityPermission].self, from: Data("""
        {"supported": {"status": "supported"},
         "partial": {"status": "partial", "claims": ["tabs.group"]},
         "unsupported": {"status": "unsupported", "reason": "chromeService", "group": "privacy"},
         "deprecated": {"status": "deprecated", "reason": "removed", "group": "privacy"}}
        """.utf8))
        #expect(rows["supported"]?.status == .supported)
        #expect(rows["partial"]?.status == .partial)
        #expect(rows["unsupported"]?.status == .unsupported)
        #expect(rows["deprecated"]?.status == .deprecated)
    }

    @Test func anUnknownPermissionStatusIsRejected() {
        // API statuses aren't permission statuses; `bridged` is invalid there.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CompatibilityPermission.self, from: Data(#"{"status": "bridged"}"#.utf8))
        }
    }

    @Test func permissionRowsCarryTheFieldsTheirStatusNeeds() throws {
        let problems = try diagnostics(claims: "{}", groups: """
        {"tabGroups": {"catalog": "extension.limit.tabGroups"}}
        """, permissions: """
        {"partial": {"status": "partial"},
         "unsupported": {"status": "unsupported"},
         "deprecated": {"status": "deprecated", "reason": "removed", "group": "tabGroups"},
         "supported": {"status": "supported"},
         "missing": {"status": "partial", "claims": ["tabs.nope"]}}
        """)
        #expect(problems.contains { $0.contains("permissions.partial") && $0.contains("claims") })
        #expect(problems.contains { $0.contains("permissions.unsupported") && $0.contains("reason") })
        #expect(problems.contains { $0.contains("permissions.unsupported") && $0.contains("group") })
        #expect(problems.contains { $0.contains("permissions.missing") && $0.contains("tabs.nope") })
        #expect(problems.count == 4)
    }

    @Test func aPartialClaimMayInheritFromItsNamespace() throws {
        // history.search is covered by the history claim; partial rows produce no line for now.
        let overlay = try overlay(claims: """
        {"history": {"status": "bridged", "implementation": "swift:history", "group": "privacy"}}
        """, groups: """
        {"privacy": {"catalog": "extension.limit.privacySettings"}}
        """, permissions: """
        {"history": {"status": "partial", "claims": ["history.search"]}}
        """)
        let problems = CompatibilityValidator.diagnostics(overlay: overlay, universe: try universe(),
                                                          implementations: implementations)
        #expect(problems.isEmpty)
        let limits = ExtensionCompatibility(overlay: overlay).limits(forPermissions: ["history"], manifestKeys: [])
        #expect(limits.isEmpty)
    }

    @Test func aPartialClaimOutsideTheUniverseIsRejected() throws {
        let problems = try diagnostics(claims: "{}", permissions: """
        {"history": {"status": "partial", "claims": ["history.notAChromeMember"]}}
        """)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("history.notAChromeMember") == true)
        #expect(problems.first?.contains("Chrome's API does not have") == true)
    }

    @Test func aPartialRowMayNameAnUnsupportedMemberAsItsGap() throws {
        // A partial permission may name the broken member; it gets no line for now.
        let overlay = try overlay(claims: """
        {"history": {"status": "unsupported", "reason": "webkitMissing", "group": "privacy"}}
        """, groups: """
        {"privacy": {"catalog": "extension.limit.privacySettings"}}
        """, permissions: """
        {"history": {"status": "partial", "claims": ["history.search"]}}
        """)
        let problems = CompatibilityValidator.diagnostics(overlay: overlay, universe: try universe(),
                                                          implementations: implementations)
        #expect(problems.isEmpty)
        let limits = ExtensionCompatibility(overlay: overlay).limits(forPermissions: ["history"], manifestKeys: [])
        #expect(limits.isEmpty)
    }

    @Test func aPartialRowThatStatesNothingIsRejected() throws {
        // Without a claim or catalog, a partial row says nothing.
        let problems = try diagnostics(claims: "{}", permissions: """
        {"history": {"status": "partial"}}
        """)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("history") == true)
        #expect(problems.first?.contains("no claims and has no catalog") == true)
    }

    @Test func everyClaimedImplementationExists() throws {
        let problems = try diagnostics(claims: """
        {"tabs": {"status": "patched", "implementation": "js:setMember"},
         "cookies": {"status": "patched", "implementation": "js:cookies.onChanged"},
         "history": {"status": "bridged", "implementation": "swift:history"},
         "downloads": {"status": "bridged", "implementation": "swift:downloads"},
         "windows": {"status": "patched", "implementation": "js:notInTheScript"},
         "runtime": {"status": "emulated", "implementation": "python:runtime"}}
        """)
        #expect(problems.count == 3)
        #expect(problems.contains { $0.contains("swift:downloads") })
        #expect(problems.contains { $0.contains("js:notInTheScript") })
        #expect(problems.contains { $0.contains("python:runtime") })
        #expect(!problems.contains { $0.contains("js:setMember") })
        #expect(!problems.contains { $0.contains("swift:history") })
    }

    @Test func aJsImplementationMustBeInTheCode() {
        // Names in comments or strings don't count as corrections.
        let implementations = CompatibilityImplementations(handlers: [], script: """
        // contextMenusKept is only named here.
        /* setMemberToo is only named here. */
        const words = "contextMenusKept setMemberToo";
        const real = (path, key, value) => {};
        """)
        #expect(!implementations.implements("js:contextMenusKept"))
        #expect(!implementations.implements("js:setMemberToo"))
        #expect(implementations.implements("js:real"))
    }

    @Test func aNamespaceKeepsItsDeclaredStatusWhenAMemberIsWorse() throws {
        let overlay = try overlay(claims: """
        {"storage": {"status": "native", "members": {
            "local": {"status": "unsupported", "reason": "notImplemented", "group": "storage", "members": {
                "get": {"status": "unsupported", "reason": "notImplemented", "group": "storage"}
            }}
        }}}
        """, groups: """
        {"storage": {"catalog": "extension.limit.storage"}}
        """)
        let problems = CompatibilityValidator.diagnostics(overlay: overlay, universe: try universe(),
                                                          implementations: implementations)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        let registry = CompatibilityRegistry(overlay: overlay)
        // Members default to the namespace; a worse member overrides only itself.
        #expect(registry.claim(for: "storage")?.status == .native)
        #expect(registry.claim(for: "storage.local")?.status == .unsupported)
        #expect(registry.claim(for: "storage.local.get")?.status == .unsupported)
        // The rollup is a summary; nothing inherits it.
        #expect(registry.status(of: "storage") == .unsupported)
    }

    // MARK: The registry

    @Test func aMemberOverrideWinsOverItsNamespace() throws {
        let overlay = try overlay(claims: """
        {"tabs": {"status": "bridged", "implementation": "swift:tabs", "members": {
            "group": {"status": "unsupported", "reason": "webkitMissing", "group": "tabGroups"}
        }}}
        """, groups: """
        {"tabGroups": {"catalog": "extension.limit.tabGroups"}}
        """)
        let registry = CompatibilityRegistry(overlay: overlay)
        #expect(registry.claim(for: "tabs")?.status == .bridged)
        #expect(registry.claim(for: "tabs")?.implementation == "swift:tabs")
        #expect(registry.claim(for: "tabs.query")?.status == .bridged)
        #expect(registry.claim(for: "tabs.query")?.implementation == "swift:tabs")
        #expect(registry.claim(for: "tabs.group")?.status == .unsupported)
        #expect(registry.claim(for: "tabs.group")?.reason == .webkitMissing)
        // The namespace keeps its declared status; the rollup is separate.
        #expect(registry.status(of: "tabs") == .unsupported)
    }

    @Test func anUnclaimedPathIsUnsupported() throws {
        let registry = CompatibilityRegistry(overlay: try overlay(claims: "{}"))
        #expect(registry.claim(for: "debugger.attach") == nil)
        #expect(registry.status(of: "debugger.attach") == .unsupported)
    }

    // MARK: The install sheet's lines

    @Test func aLimitKeepsItsSourceUntilTheCatalogHasText() {
        let limit = CompatibilityLimit(catalogKey: "extension.limit.unwritten", group: "privacy",
                                       reason: .chromeService, status: .unsupported,
                                       source: "Proxy scripts (PAC)")
        #expect(limit.text == "Proxy scripts (PAC)")
        #expect(CompatibilityText.text(for: nil, fallback: "Address bar keyword") == "Address bar keyword")
        #expect(CompatibilityText.text(for: "extension.limit.unwritten", fallback: "Tab groups") == "Tab groups")
    }

    @Test func unsupportedAndDeprecatedPermissionsShareACatalogOnce() throws {
        let overlay = try overlay(claims: """
        {"tabs": {"status": "bridged", "implementation": "swift:tabs", "members": {
            "group": {"status": "unsupported", "reason": "webkitMissing", "group": "tabGroups"}
        }},
         "history": {"status": "bridged", "implementation": "swift:history", "group": "privacy"}}
        """, groups: """
        {"privacy": {"catalog": "extension.limit.privacySettings"},
         "tabGroups": {"catalog": "extension.limit.tabGroups"},
         "gone": {"catalog": "extension.limit.gone"}}
        """, permissions: """
        {"proxy": {"status": "unsupported", "reason": "chromeService", "catalog": "extension.limit.proxyScripts",
                   "group": "privacy"},
         "tabs": {"status": "partial", "claims": ["tabs.group"]},
         "history": {"status": "partial", "claims": ["history.search"]},
         "downloads": {"status": "deprecated", "reason": "removed", "catalog": "extension.limit.gone",
                       "group": "gone"},
         "alarms": {"status": "supported"}}
        """, manifest: """
        {"omnibox": {"status": "unsupported", "reason": "notImplemented", "catalog": "extension.limit.proxyScripts",
                     "group": "privacy"}}
        """)
        let limits = ExtensionCompatibility(overlay: overlay)
            .limits(forPermissions: ["proxy", "tabs", "history", "downloads", "alarms"], manifestKeys: ["omnibox"])
        // Partial and supported rows are silent; a shared catalog gives one line with a fixed source.
        #expect(limits.count == 2)
        #expect(Set(limits.compactMap(\.catalogKey)) == ["extension.limit.proxyScripts", "extension.limit.gone"])
        let byCatalog = Dictionary(uniqueKeysWithValues: limits.compactMap { limit in
            limit.catalogKey.map { ($0, limit) }
        })
        #expect(byCatalog["extension.limit.proxyScripts"]?.source == "omnibox")
        #expect(byCatalog["extension.limit.gone"]?.status == .deprecated)
        #expect(!byCatalog.keys.contains("extension.limit.tabGroups"))
        #expect(!byCatalog.keys.contains("extension.limit.privacySettings"))
        #expect(!byCatalog.keys.contains("extension.limit.omnibox"))
    }

    // MARK: The seeded overlay

    private func shipped() throws -> (overlay: CompatibilityOverlay, universe: ChromeUniverse) {
        let overlay = try #require(ExtensionCompatibility.shared.overlay,
                                   "compatibility.json must ship with the app")
        let universe = try #require(ExtensionCompatibility.shared.universe,
                                    "chrome-api.json must ship with the app")
        return (overlay, universe)
    }

    /// All claims, nested members flattened to canonical paths.
    private func flatten(_ claims: [String: CompatibilityClaim], prefix: String = "")
        -> [(path: String, claim: CompatibilityClaim)] {
        claims.flatMap { name, claim in
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            return [(path, claim)] + flatten(claim.members ?? [:], prefix: path)
        }
        .sorted { $0.path < $1.path }
    }

    /// The string catalog: `ZZ_REPO` when the local gate copies tests out of the repo, else `#filePath`.
    private static var repo: URL {
        if let path = ProcessInfo.processInfo.environment["ZZ_REPO"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func stringCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent("Zigzag/Resources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    @MainActor @Test func everyNamespaceZigzagImplementsIsClaimed() throws {
        let (overlay, universe) = try shipped()
        let implemented = [
            "alarms", "commands", "i18n", "storage", "webNavigation",
            "tabs", "windows", "runtime", "action", "contextMenus", "cookies", "permissions",
            "scripting", "declarativeNetRequest", "webRequest",
            "history", "topSites", "bookmarks", "downloads", "notifications", "idle", "tts",
            "offscreen", "identity", "sidePanel", "proxy", "tabCapture", "userScripts",
            "system.display", "power", "extension",
        ]
        for namespace in implemented {
            #expect(universe.contains(namespace), "\(namespace) is not in chrome-api.json")
            #expect(overlay.claims[namespace] != nil, "\(namespace) is reachable but unclaimed")
        }
        // Every bridge handler for an extension namespace has a claim. `contexts` is runtime.getContexts, `contextMenusKept` is contextMenus, `passwordSaving` is one privacy setting; favicon, fetch and toolbar appearance are internal.
        for handler in ExtensionBridge.handlerNames {
            switch handler {
            case "contexts":
                #expect(overlay.claims["runtime"]?.members?["getContexts"]?.status == .bridged)
            case "contextMenusKept":
                #expect(overlay.claims["contextMenus"] != nil)
            case "passwordSaving":
                #expect(overlay.claims["privacy"] != nil)
            case "favicons", "extensionFetch", "toolbarAppearance":
                continue
            default:
                #expect(overlay.claims[handler] != nil, "bridge handler \(handler) has no namespace claim")
            }
        }
    }

    @Test func everyKnownPermissionHasAClaim() throws {
        let (overlay, _) = try shipped()
        // Keys from the removed limitNames table, so its coverage is still checked.
        let oldLimitKeys: Set<String> = [
            "sidePanel", "identity", "identity.email", "notifications", "downloads", "downloads.open",
            "idle", "offscreen", "webRequestBlocking", "history", "bookmarks", "topSites", "tabGroups",
            "fontSettings", "tts", "ttsEngine", "geolocation", "clipboardRead", "management", "privacy",
            "debugger", "pageCapture", "desktopCapture", "tabCapture", "system.display", "power",
        ]
        let known = oldLimitKeys.union(ExtensionReport.askedPermissions)
        #expect(known.count == 40)
        for permission in known.sorted() {
            #expect(overlay.permissions[permission] != nil, "\(permission) has no install-sheet row")
        }
    }

    @MainActor @Test func everyClaimedImplementationInTheShippedOverlayExists() throws {
        let (overlay, universe) = try shipped()
        let implementations = CompatibilityImplementations.shipped()
        var problems: [String] = []
        for (path, claim) in flatten(overlay.claims) {
            if !universe.contains(path) { problems.append("\(path) is not in Chrome's API") }
            switch claim.status {
            case .patched, .bridged, .emulated:
                guard let implementation = claim.implementation, !implementation.isEmpty else {
                    problems.append("\(path) is \(claim.status.rawValue) but names no implementation")
                    continue
                }
                if !implementations.implements(implementation) {
                    problems.append("\(path) names \(implementation), which does not exist")
                }
            case .unsupported, .deprecated:
                if claim.reason == nil {
                    problems.append("\(path) is \(claim.status.rawValue) but gives no reason")
                }
                if claim.group == nil {
                    problems.append("\(path) is \(claim.status.rawValue) but names no group")
                }
            case .native:
                break
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @MainActor @Test func theShippedOverlayValidatesWithNoDiagnostics() throws {
        let (overlay, universe) = try shipped()
        let problems = CompatibilityValidator.diagnostics(overlay: overlay, universe: universe,
                                                          implementations: .shipped())
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @MainActor @Test func unoverriddenMembersOfAClaimedNamespaceKeepItsImplementation() throws {
        let (overlay, universe) = try shipped()
        let registry = CompatibilityRegistry(overlay: overlay)
        let implementations = CompatibilityImplementations.shipped()
        var problems: [String] = []
        for (namespace, claim) in overlay.claims {
            guard [.patched, .bridged, .emulated].contains(claim.status) else { continue }
            let overridden = claim.members.map { Set($0.keys) } ?? []
            for path in universe.paths where path.hasPrefix(namespace + ".") {
                let member = String(path.dropFirst(namespace.count + 1))
                guard !member.contains("."), !overridden.contains(member) else { continue }
                guard let resolved = registry.claim(for: path),
                      [.patched, .bridged, .emulated].contains(resolved.status) else { continue }
                guard let implementation = resolved.implementation else {
                    problems.append("\(path) inherits \(resolved.status.rawValue) but names no implementation")
                    continue
                }
                if !implementations.implements(implementation) {
                    problems.append("\(path) inherits \(implementation), which does not exist")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Partial permission rows are silent for now; claims are kept for the install sheet later.
    @Test func aPartialPermissionRowIsSilent() throws {
        let (overlay, _) = try shipped()
        let tabCapture = ExtensionCompatibility(overlay: overlay)
            .limits(forPermissions: ["tabCapture"], manifestKeys: [])
        #expect(tabCapture.isEmpty)
        // The narrow wording is still stored.
        #expect(overlay.permissions["tabCapture"]?.status == .partial)
        let capture = try #require(overlay.claims["tabCapture"]?.members?["capture"])
        #expect(capture.group == "tabVideoCapture")
    }

    @Test func thePartialStorageRowIsSilent() throws {
        let (overlay, _) = try shipped()
        let limits = ExtensionCompatibility(overlay: overlay).limits(forPermissions: ["storage"], manifestKeys: [])
        #expect(limits.isEmpty)
        #expect(overlay.permissions["storage"]?.status == .partial)
        #expect(overlay.permissions["storage"]?.catalog == "extension.limit.storageSync")
    }

    @Test func everyGroupResolvesToACatalogEntry() throws {
        let (overlay, _) = try shipped()
        var groups: Set<String> = []
        for (_, claim) in flatten(overlay.claims) {
            if let group = claim.group { groups.insert(group) }
        }
        for row in overlay.permissions.values {
            if let group = row.group { groups.insert(group) }
        }
        for row in overlay.manifest.values {
            if let group = row.group { groups.insert(group) }
        }
        let registry = CompatibilityRegistry(overlay: overlay)
        for row in overlay.permissions.values where row.status == .partial {
            for path in row.claims ?? [] {
                if let group = registry.claim(for: path)?.group { groups.insert(group) }
            }
        }
        #expect(!groups.isEmpty)
        for group in groups.sorted() {
            #expect(overlay.groups[group]?.catalog.isEmpty == false,
                    "\(group) has no catalog key")
        }
        for (name, group) in overlay.groups {
            #expect(!group.catalog.isEmpty, "\(name) has an empty catalog key")
        }
    }

    @Test func everyLimitCatalogKeyIsTranslated() throws {
        let (overlay, _) = try shipped()
        var keys = Set(overlay.groups.values.map(\.catalog))
        for row in overlay.permissions.values {
            if let catalog = row.catalog { keys.insert(catalog) }
        }
        for row in overlay.manifest.values {
            if let catalog = row.catalog { keys.insert(catalog) }
        }
        let catalog = try Self.stringCatalog()
        var unwritten: [String] = []
        var noChinese: [String] = []
        var noEnglish: [String] = []
        var wrongEnglish: [String] = []
        // Pre-overlay wording, kept as each key's English value.
        let expectedEnglish: [String: String] = [
            "extension.limit.tabGroups": "Tab groups",
            "extension.limit.tabActions": "Some tab actions",
            "extension.limit.tabHousekeeping": "Discarding and highlighting tabs",
            "extension.limit.windowsPopup": "Popup windows",
            "extension.limit.runtime": "Restarting Zigzag",
            "extension.limit.runtimeContexts": "Open pages (background, popup, side panel and offscreen only; no tabs, subframes, developer tools or document IDs)",
            "extension.limit.backgroundPage": "The background page (Manifest V2 only; Manifest V3 pages get “You do not have a background page.”)",
            "extension.limit.action": "Toolbar button settings",
            "extension.limit.notifications": "Notifications",
            "extension.limit.sidePanel": "Side panel",
            "extension.limit.systemDisplay": "Display information",
            "extension.limit.power": "Keeping your Mac awake",
            "extension.limit.signIn": "Signing in with your account",
            "extension.limit.bookmarks": "Your bookmarks",
            "extension.limit.downloads": "Downloads",
            "extension.limit.tabCapture": "Recording tabs",
            "extension.limit.tabVideoCapture": "Tab video capture",
            "extension.limit.cookies": "Cookie details",
            "extension.limit.cookiePartitions": "Cookie partition details",
            "extension.limit.hostAccessRequests": "Site access requests",
            "extension.limit.storage": "Stored extension settings",
            "extension.limit.storageSync": "Settings synced between Macs",
            "extension.limit.localScripts": "Scripts on local files",
            "extension.limit.blockingRules": "Blocking rules",
            "extension.limit.staticRuleChanges": "Changes to static blocking rules",
            "extension.limit.matchedRuleDebugging": "Matched-rule debugging",
            "extension.limit.webRequestBlocking": "Blocking requests the old way",
            "extension.limit.languageDetection": "Language detection",
            "extension.limit.legacyExtension": "Legacy extension APIs",
            "extension.limit.sessions": "Closed tabs and sessions",
            "extension.limit.search": "Search settings",
            "extension.limit.debugger": "Debugging pages",
            "extension.limit.fontSettings": "Font settings",
            "extension.limit.privacySettings": "Privacy settings",
            "extension.limit.management": "Managing other extensions",
            "extension.limit.pageCapture": "Saving pages",
            "extension.limit.desktopCapture": "Recording your screen",
            "extension.limit.publicSuffix": "Domain names",
            "extension.limit.devtools": "Developer tools",
            "extension.limit.contentSettings": "Content settings",
            "extension.limit.readingList": "Reading list",
            "extension.limit.tts": "Reading aloud",
            "extension.limit.geolocation": "Your location",
            "extension.limit.clipboardRead": "Reading what you copy",
            "extension.limit.proxyScripts": "Proxy scripts (PAC)",
            "extension.limit.deprecatedChannel": "Deprecated Google APIs",
        ]
        #expect(keys == Set(expectedEnglish.keys))
        for key in keys.sorted() {
            let sentinel = "⟨no catalog text⟩"
            if CompatibilityText.text(for: key, fallback: sentinel) == sentinel { unwritten.append(key) }
            let localizations = (catalog[key] as? [String: Any])?["localizations"] as? [String: Any]
            let chinese = (((localizations?["zh-Hans"] as? [String: Any])?["stringUnit"]
                as? [String: Any])?["value"] as? String)
            if chinese?.isEmpty != false { noChinese.append(key) }
            let english = (((localizations?["en"] as? [String: Any])?["stringUnit"]
                as? [String: Any])?["value"] as? String)
            if let english, !english.isEmpty {
                if english != expectedEnglish[key] { wrongEnglish.append("\(key): \(english)") }
            } else {
                noEnglish.append(key)
            }
        }
        #expect(!keys.isEmpty)
        #expect(unwritten.isEmpty, "No CompatibilityText case for: \(unwritten)")
        #expect(noChinese.isEmpty, "No zh-Hans value for: \(noChinese)")
        #expect(noEnglish.isEmpty, "No en value for: \(noEnglish)")
        #expect(wrongEnglish.isEmpty, "Wording changed for: \(wrongEnglish)")
    }

    @Test func everyPermissionRowWordsItsLines() throws {
        let (overlay, _) = try shipped()
        let compatibility = ExtensionCompatibility(overlay: overlay)
        for (name, row) in overlay.permissions {
            let limits = compatibility.limits(forPermissions: [name], manifestKeys: [])
            switch row.status {
            case .supported, .partial:
                // Only unsupported and deprecated permissions get a line.
                #expect(limits.isEmpty, "\(name) is \(row.status.rawValue) but has a limit line")
            case .unsupported, .deprecated:
                #expect(limits.count == 1, "\(name) should have one line, not \(limits.count)")
                #expect(limits.first?.status == row.status)
            }
            for limit in limits {
                #expect(limit.catalogKey != nil, "\(name) has a line with no catalog key")
                #expect(limit.text != "", "\(name) has an empty line")
            }
        }
        let coveredSupported = ["bookmarks", "downloads", "identity", "notifications",
                                "power", "sidePanel", "system.display"]
        for name in coveredSupported {
            #expect(overlay.permissions[name]?.status == .supported, "\(name) should be supported")
            #expect(compatibility.limits(forPermissions: [name], manifestKeys: []).isEmpty,
                    "\(name) should have no line")
        }
        // tabCapture is partial and silent; its wording is kept.
        #expect(overlay.permissions["tabCapture"]?.status == .partial)
        #expect(compatibility.limits(forPermissions: ["tabCapture"], manifestKeys: []).isEmpty)
        // Address bar keywords work in the command bar (#324): no line.
        #expect(overlay.manifest["omnibox"]?.status == .supported)
        #expect(compatibility.limits(forPermissions: [], manifestKeys: ["omnibox"]).isEmpty)
    }

    @MainActor @Test func aClaimCannotGrantAnything() throws {
        let (overlay, _) = try shipped()
        let handlers = ExtensionBridge.handlerNames
        let permissions = ExtensionBridgeScript.permissions
        let granted = ExtensionBridgeScript.granted
        let registry = CompatibilityRegistry(overlay: overlay)
        let compatibility = ExtensionCompatibility(overlay: overlay)
        _ = compatibility.limits(forPermissions: Set(overlay.permissions.keys),
                                  manifestKeys: Set(overlay.manifest.keys))
        // The registry has no setter, so reading the overlay can't change a permission.
        #expect(registry.claim(for: "history")?.status == .bridged)
        #expect(CompatibilityRegistry(overlay: overlay).claimedPaths == registry.claimedPaths)
        #expect(ExtensionBridge.handlerNames == handlers)
        #expect(ExtensionBridgeScript.permissions == permissions)
        #expect(ExtensionBridgeScript.granted == granted)
    }
}

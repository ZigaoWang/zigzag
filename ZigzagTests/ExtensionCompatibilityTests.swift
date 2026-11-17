import Foundation
import Testing
@testable import Zigzag

/// The claim overlay over chrome-api.json: the validator that keeps it honest, and the registry that says what it
/// means. The fixtures here are inline JSON; the real compatibility.json lands with the claims themselves.
struct ExtensionCompatibilityTests {
    /// The bridge's handler names and the corrections script's own words, without the app bundle: the validator
    /// never trusts the overlay to describe itself.
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

    /// An overlay from the parts a test cares about; the rest empty, as the real overlay leaves paths it does not
    /// claim.
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

        // Chrome has storage.local.get; it has no storage.local.erase.
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
        // The same canonical path reached two ways: through storage's members and as a claim of its own.
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
        // The API statuses are not permission statuses: `bridged` has no meaning in the install sheet.
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
        // history.search has no claim of its own; the history claim covers it, and the sheet still gets its line.
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
        #expect(limits.count == 1)
        #expect(limits.first?.catalogKey == "extension.limit.privacySettings")
        #expect(limits.first?.status == .partial)
        #expect(limits.first?.source == "history.search")
    }

    @Test func aPartialClaimOutsideTheUniverseIsRejected() throws {
        let problems = try diagnostics(claims: "{}", permissions: """
        {"history": {"status": "partial", "claims": ["history.notAChromeMember"]}}
        """)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("history.notAChromeMember") == true)
        #expect(problems.first?.contains("Chrome's API does not have") == true)
    }

    @Test func aPartialClaimUnderAnUnsupportedNamespaceIsRejected() throws {
        let problems = try diagnostics(claims: """
        {"history": {"status": "unsupported", "reason": "webkitMissing", "group": "privacy"}}
        """, groups: """
        {"privacy": {"catalog": "extension.limit.privacySettings"}}
        """, permissions: """
        {"history": {"status": "partial", "claims": ["history.search"]}}
        """)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("history.search") == true)
        #expect(problems.first?.contains("unsupported") == true)
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
        // A name a comment or a string mentions is not a correction; a renamed one must not keep passing there.
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
        // The namespace is the default for its members; a worse member overrides only itself.
        #expect(registry.claim(for: "storage")?.status == .native)
        #expect(registry.claim(for: "storage.local")?.status == .unsupported)
        #expect(registry.claim(for: "storage.local.get")?.status == .unsupported)
        // The rollup is a separate summary; nothing inherits it.
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
        // The namespace keeps its declared answer; the rollup is a separate presentation summary.
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

    @Test func installLinesCarryThePermissionStatusAndShareACatalogOnce() throws {
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
        // A shared catalog is one line, with a deterministic source, and a supported permission has no line.
        #expect(limits.count == 4)
        #expect(Set(limits.compactMap(\.catalogKey)) == ["extension.limit.proxyScripts", "extension.limit.tabGroups",
                                                         "extension.limit.privacySettings", "extension.limit.gone"])
        let byCatalog = Dictionary(uniqueKeysWithValues: limits.compactMap { limit in
            limit.catalogKey.map { ($0, limit) }
        })
        #expect(byCatalog["extension.limit.proxyScripts"]?.source == "omnibox")
        #expect(byCatalog["extension.limit.tabGroups"]?.status == .unsupported)
        #expect(byCatalog["extension.limit.privacySettings"]?.status == .partial)
        #expect(byCatalog["extension.limit.gone"]?.status == .deprecated)
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

    /// Every claim, nested members flattened to their canonical path.
    private func flatten(_ claims: [String: CompatibilityClaim], prefix: String = "")
        -> [(path: String, claim: CompatibilityClaim)] {
        claims.flatMap { name, claim in
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            return [(path, claim)] + flatten(claim.members ?? [:], prefix: path)
        }
        .sorted { $0.path < $1.path }
    }

    /// The app's string catalog. The local gate copies the test file out of the repository, so `ZZ_REPO` names it;
    /// an Xcode build compiles it in place, where `#filePath` does.
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
        // Every bridge handler that answers an extension's namespace has a claim. `contexts` answers
        // runtime.getContexts and `contextMenusKept` answers contextMenus; the favicon and fetch handlers are
        // Zigzag's own plumbing, not a Chrome namespace.
        for handler in ExtensionBridge.handlerNames {
            switch handler {
            case "contexts":
                #expect(overlay.claims["runtime"]?.members?["getContexts"]?.status == .bridged)
            case "contextMenusKept":
                #expect(overlay.claims["contextMenus"] != nil)
            case "favicons", "extensionFetch":
                continue
            default:
                #expect(overlay.claims[handler] != nil, "bridge handler \(handler) has no namespace claim")
            }
        }
    }

    @Test func everyKnownPermissionHasAClaim() throws {
        let (overlay, _) = try shipped()
        // The old limitNames table's keys, verbatim. ExtensionReport keeps it private, so the union the plan names
        // is written here; a permission added to either table without a claim fails this test.
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

    @Test func theStorageLimitReachesTheSheet() throws {
        let (overlay, _) = try shipped()
        let limits = ExtensionCompatibility(overlay: overlay).limits(forPermissions: ["storage"], manifestKeys: [])
        #expect(limits.count == 1)
        #expect(limits.first?.catalogKey == "extension.limit.storageSync")
        #expect(limits.first?.status == .partial)
        #expect(limits.first?.text == "Settings that stay on this Mac")
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
        // The wording a person saw before the overlay, kept as each catalog key's English value.
        let expectedEnglish: [String: String] = [
            "extension.limit.tabGroups": "Tab groups",
            "extension.limit.tabActions": "Some tab actions",
            "extension.limit.windowsPopup": "Popup windows",
            "extension.limit.runtime": "Restarting Zigzag",
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
            "extension.limit.hostAccessRequests": "Site access requests",
            "extension.limit.storage": "Stored extension settings",
            "extension.limit.storageSync": "Settings that stay on this Mac",
            "extension.limit.localScripts": "Scripts on local files",
            "extension.limit.blockingRules": "Blocking rules",
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
            "extension.limit.addressBarKeyword": "Address bar keyword",
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
            case .supported:
                #expect(limits.isEmpty, "\(name) is supported but has a limit line")
            case .partial:
                #expect(!limits.isEmpty, "\(name) is partial but has no limit line")
                #expect(limits.allSatisfy { $0.status == .partial }, "\(name) has a line that is not partial")
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
        // Tab video capture is the one covered row that keeps a limit; tab audio capture works.
        #expect(overlay.permissions["tabCapture"]?.status == .partial)
        let capture = compatibility.limits(forPermissions: ["tabCapture"], manifestKeys: [])
        #expect(capture.count == 1)
        #expect(capture.first?.catalogKey == "extension.limit.tabVideoCapture")
        #expect(capture.first?.status == .partial)
        #expect(capture.first?.text == "Tab video capture")
        let omnibox = compatibility.limits(forPermissions: [], manifestKeys: ["omnibox"])
        #expect(omnibox.count == 1)
        #expect(omnibox.first?.catalogKey == "extension.limit.addressBarKeyword")
        #expect(omnibox.first?.text == "Address bar keyword")
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
        // The registry's only surface is claimedPaths, claim(for:) and status(of:): there is no setter for a
        // permission's state, so reading the overlay cannot grant, widen or drop one.
        #expect(registry.claim(for: "history")?.status == .bridged)
        #expect(CompatibilityRegistry(overlay: overlay).claimedPaths == registry.claimedPaths)
        #expect(ExtensionBridge.handlerNames == handlers)
        #expect(ExtensionBridgeScript.permissions == permissions)
        #expect(ExtensionBridgeScript.granted == granted)
    }
}

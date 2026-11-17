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

    private func diagnostics(claims: String, groups: String = "{}") throws -> [String] {
        CompatibilityValidator.diagnostics(overlay: try overlay(claims: claims, groups: groups),
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

    @Test func aNamespaceIsNeverBetterThanItsWorstMember() throws {
        let problems = try diagnostics(claims: """
        {"storage": {"status": "native", "members": {
            "local": {"status": "unsupported", "reason": "notImplemented", "group": "storage", "members": {
                "get": {"status": "unsupported", "reason": "notImplemented", "group": "storage"}
            }}
        }}}
        """, groups: """
        {"storage": {"catalog": "extension.limit.storage"}}
        """)
        #expect(problems.count == 1)
        #expect(problems.first?.contains("storage") == true)
        #expect(problems.first?.contains("storage.local") == true)
        #expect(problems.first?.contains("unsupported") == true)
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
        #expect(registry.claim(for: "tabs.query")?.status == .bridged)
        #expect(registry.claim(for: "tabs.query")?.implementation == "swift:tabs")
        #expect(registry.claim(for: "tabs.group")?.status == .unsupported)
        #expect(registry.claim(for: "tabs.group")?.reason == .webkitMissing)
        // A namespace shows its worst member, so it cannot look better than the claims under it.
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

    @Test func installLinesComeFromThePermissionsAndManifestKeys() throws {
        let overlay = try overlay(claims: """
        {"tabs": {"status": "bridged", "implementation": "swift:tabs", "members": {
            "group": {"status": "unsupported", "reason": "webkitMissing", "group": "tabGroups"}
        }}}
        """, groups: """
        {"privacy": {"catalog": "extension.limit.privacySettings"},
         "tabGroups": {"catalog": "extension.limit.tabGroups"}}
        """, permissions: """
        {"proxy": {"status": "unsupported", "reason": "chromeService", "catalog": "extension.limit.proxyScripts",
                   "group": "privacy"},
         "history": {"status": "bridged"}}
        """, manifest: """
        {"omnibox": {"status": "unsupported", "reason": "notImplemented", "catalog": "extension.limit.omnibox",
                     "group": "privacy"}}
        """)
        let compatibility = ExtensionCompatibility(overlay: overlay)
        let limits = compatibility.limits(forPermissions: ["proxy", "history"], manifestKeys: ["omnibox"])
        #expect(Set(limits.map(\.catalogKey)) == ["extension.limit.proxyScripts", "extension.limit.omnibox"])
        #expect(limits.allSatisfy { $0.group == "privacy" })
        #expect(limits.allSatisfy { $0.status == .unsupported })
    }
}

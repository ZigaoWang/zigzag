import Foundation
import Testing
import WebKit
@testable import Zigzag

/// Firefox's claim overlay: the same model, registry and validator as Chrome's, over its own universe
/// (`firefox-api.json`), and the package kind that selects it through `ExtensionReport` to the install sheet. A
/// Firefox-only member lives here and never in Chrome's matrix; a Chrome package keeps `compatibility.json`.
@MainActor
@Suite(.serialized)
struct FirefoxCompatibilityTests {
    // MARK: The shipping pair

    private static func shipped(_ kind: ExtensionKind) throws -> (overlay: CompatibilityOverlay, universe: ChromeUniverse) {
        let compatibility = ExtensionCompatibility.shared(for: kind)
        let overlay = try #require(compatibility.overlay, "\(kind.rawValue)'s overlay must ship with the app")
        let universe = try #require(compatibility.universe, "\(kind.rawValue)'s universe must ship with the app")
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

    /// The app's string catalog; `ZZ_REPO` names the repository in the local gate.
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

    // MARK: The overlay against its universe

    @Test func theFirefoxOverlayValidatesWithNoDiagnostics() throws {
        let (overlay, universe) = try Self.shipped(.firefox)
        let problems = CompatibilityValidator.diagnostics(overlay: overlay, universe: universe,
                                                          implementations: .shipped())
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Every implementation an `emulated`/`patched`/`bridged` claim names is in the code that answers it — the
    /// polyfill included, since `getBrowserInfo` and `getPlatformInfo` live there and nowhere else.
    @Test func everyFirefoxClaimedImplementationExists() throws {
        let (overlay, universe) = try Self.shipped(.firefox)
        let implementations = CompatibilityImplementations.shipped()
        var problems: [String] = []
        for (path, claim) in flatten(overlay.claims) {
            if !universe.contains(path) { problems.append("\(path) is not in Firefox's API") }
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
                if claim.reason == nil { problems.append("\(path) is \(claim.status.rawValue) but gives no reason") }
                if claim.group == nil { problems.append("\(path) is \(claim.status.rawValue) but names no group") }
            case .native:
                break
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// The bridge answers the same namespaces for a Firefox package; each one that Firefox names is claimed, so no
    /// reachable answer goes unrecorded.
    @Test func everyFirefoxBridgeNamespaceIsClaimed() throws {
        let (overlay, universe) = try Self.shipped(.firefox)
        for handler in ExtensionBridge.handlerNames {
            switch handler {
            case "contexts":
                #expect(overlay.claims["runtime"]?.members?["getContexts"]?.status == .bridged)
            case "contextMenusKept":
                #expect(overlay.claims["contextMenus"] != nil || overlay.claims["menus"] != nil)
            case "favicons", "extensionFetch", "system.display", "tts", "power", "offscreen", "sidePanel", "tabCapture":
                // Zigzag's own plumbing, or names Firefox does not have.
                continue
            default:
                #expect(universe.contains(handler), "\(handler) is not in firefox-api.json")
                #expect(overlay.claims[handler] != nil, "bridge handler \(handler) has no namespace claim")
            }
        }
    }

    // MARK: The facade

    @Test func theFacadeAnswersBrowserAndPlatformInfo() throws {
        let (overlay, universe) = try Self.shipped(.firefox)
        for member in ["getBrowserInfo", "getPlatformInfo"] {
            let claim = try #require(overlay.claims["runtime"]?.members?[member], "runtime.\(member)")
            #expect(claim.status == .emulated, "runtime.\(member)")
            #expect(claim.implementation?.hasPrefix("js:") == true, "runtime.\(member) names no js: implementation")
            #expect(universe.contains("runtime.\(member)"))
        }
    }

    // MARK: Firefox-only limits

    @Test func firefoxOnlyFeaturesAreClaimedUnsupported() throws {
        let (overlay, _) = try Self.shipped(.firefox)
        for namespace in ["contextualIdentities", "browserSettings", "pkcs11", "dns", "theme"] {
            let claim = try #require(overlay.claims[namespace], "\(namespace) is not claimed")
            #expect(claim.status == .unsupported, "\(namespace) should be unsupported")
            #expect(claim.reason != nil, "\(namespace) gives no reason")
            #expect(claim.group != nil, "\(namespace) names no group")
        }
    }

    // MARK: Permission rows

    @Test func everyFirefoxPermissionRowFollowsTheNoiseRule() throws {
        let (overlay, _) = try Self.shipped(.firefox)
        let compatibility = ExtensionCompatibility(overlay: overlay)
        for (name, row) in overlay.permissions {
            let limits = compatibility.limits(forPermissions: [name], manifestKeys: [])
            switch row.status {
            case .supported, .partial:
                #expect(limits.isEmpty, "\(name) is \(row.status.rawValue) but has a limit line")
            case .unsupported, .deprecated:
                #expect(limits.count == 1, "\(name) should have one line, not \(limits.count)")
                #expect(limits.first?.status == row.status)
                #expect(limits.first?.catalogKey != nil, "\(name) has a line with no catalog key")
                #expect(limits.first?.text != "", "\(name) has an empty line")
            }
        }
        // A seed of Mozilla's documented permissions, by the answer each gets.
        for name in ["bookmarks", "downloads", "downloads.open", "history", "identity", "idle", "nativeMessaging",
                     "notifications", "topSites", "userScripts", "webNavigation", "webRequest"] {
            #expect(overlay.permissions[name]?.status == .supported, "\(name) should be supported")
            #expect(compatibility.limits(forPermissions: [name], manifestKeys: []).isEmpty, "\(name) should be silent")
        }
        for name in ["storage", "tabs", "menus"] {
            #expect(overlay.permissions[name]?.status == .partial, "\(name) should be partial")
            #expect(compatibility.limits(forPermissions: [name], manifestKeys: []).isEmpty, "\(name) should be silent")
        }
        for name in ["contextualIdentities", "browserSettings", "pkcs11", "dns", "theme"] {
            #expect(overlay.permissions[name]?.status == .unsupported, "\(name) should be unsupported")
            #expect(compatibility.limits(forPermissions: [name], manifestKeys: []).count == 1, "\(name) should have one line")
        }
    }

    // MARK: Catalog keys

    @Test func everyFirefoxCatalogKeyIsTranslated() throws {
        let (overlay, _) = try Self.shipped(.firefox)
        var keys = Set(overlay.groups.values.map(\.catalog))
        for row in overlay.permissions.values { if let catalog = row.catalog { keys.insert(catalog) } }
        for row in overlay.manifest.values { if let catalog = row.catalog { keys.insert(catalog) } }
        let catalog = try Self.stringCatalog()
        var unwritten: [String] = []
        var noChinese: [String] = []
        var noEnglish: [String] = []
        var wrongEnglish: [String] = []
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
            "extension.limit.signIn": "Signing in with your account",
            "extension.limit.bookmarks": "Your bookmarks",
            "extension.limit.downloads": "Downloads",
            "extension.limit.cookies": "Cookie details",
            "extension.limit.hostAccessRequests": "Site access requests",
            "extension.limit.storage": "Stored extension settings",
            "extension.limit.storageSync": "Settings synced between Macs",
            "extension.limit.localScripts": "Scripts on local files",
            "extension.limit.blockingRules": "Blocking rules",
            "extension.limit.staticRuleChanges": "Changes to static blocking rules",
            "extension.limit.languageDetection": "Language detection",
            "extension.limit.legacyExtension": "Legacy extension APIs",
            "extension.limit.sessions": "Closed tabs and sessions",
            "extension.limit.search": "Search settings",
            "extension.limit.management": "Managing other extensions",
            "extension.limit.addressBarKeyword": "Address bar keyword",
            "extension.limit.devtools": "Developer tools",
            "extension.limit.tts": "Reading aloud",
            "extension.limit.geolocation": "Your location",
            "extension.limit.clipboardRead": "Reading what you copy",
            "extension.limit.proxyScripts": "Proxy scripts (PAC)",
            "extension.limit.webRequestBlocking": "Blocking requests the old way",
            "extension.limit.privacySettings": "Privacy settings",
            // Firefox-only lines: Zigzag ships no Firefox feature behind them.
            "extension.limit.contextualIdentities": "Containers",
            "extension.limit.browserSettings": "Browser settings",
            "extension.limit.pkcs11": "Security modules",
            "extension.limit.dns": "DNS resolution",
            "extension.limit.theme": "Themes",
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

        // A Firefox-only key is Firefox's alone: Chrome's matrix keeps its own key set.
        let (chrome, _) = try Self.shipped(.chromium)
        var chromeKeys = Set(chrome.groups.values.map(\.catalog))
        for row in chrome.permissions.values { if let catalog = row.catalog { chromeKeys.insert(catalog) } }
        for row in chrome.manifest.values { if let catalog = row.catalog { chromeKeys.insert(catalog) } }
        let firefoxOnly: Set<String> = ["extension.limit.contextualIdentities", "extension.limit.browserSettings",
                                        "extension.limit.pkcs11", "extension.limit.dns", "extension.limit.theme"]
        #expect(keys.subtracting(chromeKeys) == firefoxOnly)
    }

    // MARK: Kind threads through the report

    @Test func aChromePackageStillUsesTheChromeOverlay() throws {
        let (chrome, chromeUniverse) = try Self.shipped(.chromium)
        let (firefox, firefoxUniverse) = try Self.shipped(.firefox)
        // `tabCapture` is Chrome's and only Chrome's: the two overlays are two files.
        #expect(chrome.claims["tabCapture"] != nil)
        #expect(firefox.claims["tabCapture"] == nil)
        #expect(chromeUniverse.contains("tabCapture"))
        #expect(!firefoxUniverse.contains("tabCapture"))
        #expect(chrome.permissions["storage"]?.catalog == "extension.limit.storageSync")
        #expect(firefox.permissions["storage"]?.catalog == "extension.limit.storageSync")
    }

    // MARK: The install sheet

    /// A Firefox manifest the review sheet reads, with the Firefox-only permission it names.
    private static func manifest(_ geckoID: String, _ permissions: [String]) -> [String: Any] {
        ["manifest_version": 2, "name": "Firefox Test", "version": "1.0",
         "browser_specific_settings": ["gecko": ["id": geckoID]], "permissions": permissions]
    }

    @Test func aFirefoxInstallSheetNamesItsUnsupportedPermissions() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("zigzag-firefox-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fixture.xpi")
        try Self.xpi(Self.manifest("sheet@zigzag.test",
                                   ["storage", "tabs", "menus", "contextualIdentities", "theme"])).write(to: url)

        let result = await ExtensionStore.prepareInstallXPI(at: url)
        guard case .success(let prepared) = result else {
            Issue.record("expected a prepared install, got \(result)")
            return
        }
        defer { ExtensionStore.discard(prepared) }
        #expect(prepared.kind == .firefox)
        let texts = Set(prepared.report.limits.map(\.text))
        let sources = Set(prepared.report.limits.map(\.source))
        // The Firefox-only permissions are named, by the overlay's own words.
        #expect(texts.contains("Containers"), "\(texts)")
        #expect(texts.contains("Themes"), "\(texts)")
        // A partial row is silent (PR A's rule): storage, tabs and menus add nothing.
        for name in ["storage", "tabs", "menus"] {
            #expect(!sources.contains(name), "\(name) should not be a line")
        }
        #expect(!texts.contains("Settings synced between Macs"))
        #expect(!texts.contains("Tab groups"))
    }

    // MARK: Fixture

    /// An XPI made byte by byte, as FirefoxInstallTests writes one: stored entries, central index and end record.
    private struct TestXPI {
        struct Entry { var name: String; var data = Data(); var mode: UInt32 = 0o100644 }
        var entries: [Entry]

        var data: Data {
            var archive = Data(), index = Data()
            func u16(_ value: UInt16, into bytes: inout Data) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
            func u32(_ value: UInt32, into bytes: inout Data) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
            for entry in entries {
                let name = Data(entry.name.utf8), crc = PackageZip.crc32([UInt8](entry.data)), offset = UInt32(archive.count)
                u32(0x0403_4B50, into: &archive); u16(20, into: &archive); u16(0, into: &archive); u16(0, into: &archive)
                u16(0, into: &archive); u16(0, into: &archive); u32(crc, into: &archive)
                u32(UInt32(entry.data.count), into: &archive); u32(UInt32(entry.data.count), into: &archive)
                u16(UInt16(name.count), into: &archive); u16(0, into: &archive); archive.append(name); archive.append(entry.data)
                u32(0x0201_4B50, into: &index); u16(0x0314, into: &index); u16(20, into: &index); u16(0, into: &index)
                u16(0, into: &index); u16(0, into: &index); u16(0, into: &index); u32(crc, into: &index)
                u32(UInt32(entry.data.count), into: &index); u32(UInt32(entry.data.count), into: &index)
                u16(UInt16(name.count), into: &index); u16(0, into: &index); u16(0, into: &index)
                u16(0, into: &index); u16(0, into: &index); u32(entry.mode << 16, into: &index); u32(offset, into: &index)
                index.append(name)
            }
            let start = UInt32(archive.count)
            archive.append(index)
            u32(0x0605_4B50, into: &archive); u16(0, into: &archive); u16(0, into: &archive)
            u16(UInt16(entries.count), into: &archive); u16(UInt16(entries.count), into: &archive)
            u32(UInt32(index.count), into: &archive); u32(start, into: &archive); u16(0, into: &archive)
            return archive
        }
    }

    private static func xpi(_ manifest: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        return TestXPI(entries: [.init(name: "manifest.json", data: json)]).data
    }
}

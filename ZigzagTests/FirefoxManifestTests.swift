import Foundation
import Testing
@testable import Zigzag

struct FirefoxManifestTests {
    /// A manifest as text, so two of them compare deeply whatever their nesting.
    private func text(_ manifest: [String: Any]) throws -> String {
        let data = try #require(try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
                                "manifest is not valid JSON: \(manifest)")
        return String(decoding: data, as: UTF8.self)
    }

    @Test func mv2BackgroundScriptsAreUnchanged() throws {
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "background": ["scripts": ["a.js", "b.js"]],
        ]
        #expect(try text(FirefoxManifest.normalized(manifest)) == text(manifest))
    }

    @Test func sidebarActionGainsASidePanelTwin() {
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "sidebar_action": [
                "default_panel": "panel.html",
                "default_title": "Panel",
                "default_icon": "icon.png",
            ],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        let panel = normalized["side_panel"] as? [String: Any]
        #expect(panel?["default_path"] as? String == "panel.html")
        let sidebar = normalized["sidebar_action"] as? [String: Any]
        #expect(sidebar?["default_panel"] as? String == "panel.html")
        #expect(sidebar?["default_title"] as? String == "Panel")
        #expect(sidebar?["default_icon"] as? String == "icon.png")
    }

    @Test func browserActionGainsTheActionWebKitReads() {
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "browser_action": [
                "default_popup": "popup.html",
                "default_title": "Popup",
                "default_icon": "icon.png",
            ],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        let action = normalized["action"] as? [String: Any]
        #expect(action?["default_popup"] as? String == "popup.html")
        #expect(action?["default_title"] as? String == "Popup")
        #expect(action?["default_icon"] as? String == "icon.png")
        // Firefox's own key stays, and the manifest handed in is untouched.
        #expect(normalized["browser_action"] as? [String: Any] != nil)
        #expect(manifest["action"] == nil)
        // The same manifest again changes nothing.
        #expect((try? text(FirefoxManifest.normalized(normalized))) == (try? text(normalized)))
    }

    @Test func anExistingActionIsKeptOverBrowserAction() {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "action": ["default_popup": "modern.html"],
            "browser_action": ["default_popup": "old.html"],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        #expect((normalized["action"] as? [String: Any])?["default_popup"] as? String == "modern.html")
    }

    @Test func pageActionGainsActionWhenThereIsNoToolbarButton() {
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "page_action": ["default_popup": "page.html"],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        #expect((normalized["action"] as? [String: Any])?["default_popup"] as? String == "page.html")
        // A browser action wins over a page action when both are there.
        let both: [String: Any] = [
            "manifest_version": 2,
            "browser_action": ["default_popup": "toolbar.html"],
            "page_action": ["default_popup": "page.html"],
        ]
        let withBoth = FirefoxManifest.normalized(both)
        #expect((withBoth["action"] as? [String: Any])?["default_popup"] as? String == "toolbar.html")
    }

    @Test func existingWorkerAndSidePanelAreKept() {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "background": ["scripts": ["a.js"], "service_worker": "own-worker.js", "type": "module"],
            "sidebar_action": ["default_panel": "panel.html"],
            "side_panel": ["default_path": "own-panel.html"],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        let background = normalized["background"] as? [String: Any]
        #expect(background?["service_worker"] as? String == "own-worker.js")
        #expect(background?["type"] as? String == "module")
        let panel = normalized["side_panel"] as? [String: Any]
        #expect(panel?["default_path"] as? String == "own-panel.html")
    }

    @Test func mv3HostPatternsMoveOutOfPermissions() {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "permissions": ["storage", "https://example.com/*", "<all_urls>", "tabs"],
            "optional_permissions": ["*://*.example.org/*", "alarms"],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        #expect(normalized["permissions"] as? [String] == ["storage", "tabs"])
        #expect(normalized["host_permissions"] as? [String] == ["https://example.com/*", "<all_urls>"])
        #expect(normalized["optional_permissions"] as? [String] == ["alarms"])
        #expect(normalized["optional_host_permissions"] as? [String] == ["*://*.example.org/*"])
    }

    @Test func hostPatternsMergeWithExistingOnes() {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "permissions": ["storage", "https://a.example/*", "https://b.example/*", "https://a.example/*"],
            "host_permissions": ["https://existing.example/*", "https://b.example/*"],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        #expect(normalized["host_permissions"] as? [String]
                == ["https://existing.example/*", "https://b.example/*", "https://a.example/*"])
        #expect(normalized["permissions"] as? [String] == ["storage"])
    }

    @Test func mv3StringContentSecurityPolicyBecomesAPagePolicy() {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "content_security_policy": "script-src 'self'; object-src 'self'",
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        let policy = normalized["content_security_policy"] as? [String: Any]
        #expect(policy?["extension_pages"] as? String == "script-src 'self'; object-src 'self'")
    }

    @Test func mv2ContentSecurityPolicyIsUnchanged() throws {
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "content_security_policy": "script-src 'self'; object-src 'self'",
        ]
        #expect(try text(FirefoxManifest.normalized(manifest)) == text(manifest))
    }

    @Test func mv2WebAccessibleResourcesBecomeObjects() {
        let manifest: [String: Any] = [
            "manifest_version": 2,
            "web_accessible_resources": ["a.js", "b.css"],
        ]
        let normalized = FirefoxManifest.normalized(manifest)
        let resources = normalized["web_accessible_resources"] as? [[String: Any]]
        #expect(resources?.count == 1)
        #expect(resources?.first?["resources"] as? [String] == ["a.js", "b.css"])
        #expect(resources?.first?["matches"] as? [String] == ["<all_urls>"])
    }

    @Test func mv3WebAccessibleResourcesAreUnchanged() throws {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "web_accessible_resources": [
                ["resources": ["a.js"], "matches": ["https://example.com/*"]],
            ],
        ]
        #expect(try text(FirefoxManifest.normalized(manifest)) == text(manifest))
    }

    @Test func normalizingTwiceChangesNothing() throws {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "background": ["scripts": ["a.js", "b.js"]],
            "sidebar_action": ["default_panel": "panel.html", "default_title": "Panel"],
            "permissions": ["storage", "https://example.com/*"],
            "optional_permissions": ["<all_urls>", "alarms"],
            "content_security_policy": "script-src 'self'",
        ]
        let once = FirefoxManifest.normalized(manifest)
        #expect(try text(FirefoxManifest.normalized(once)) == text(once))

        let mv2: [String: Any] = [
            "manifest_version": 2,
            "web_accessible_resources": ["a.js", "b.css"],
            "sidebar_action": ["default_panel": "panel.html"],
        ]
        let mv2Once = FirefoxManifest.normalized(mv2)
        #expect(try text(FirefoxManifest.normalized(mv2Once)) == text(mv2Once))
    }

    @Test func normalizingLeavesItsInputAlone() throws {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "background": ["scripts": ["a.js", "b.js"]],
            "sidebar_action": ["default_panel": "panel.html"],
            "permissions": ["storage", "https://example.com/*"],
            "optional_permissions": ["<all_urls>", "alarms"],
            "content_security_policy": "script-src 'self'",
        ]
        let before = try text(manifest)
        _ = FirefoxManifest.normalized(manifest)
        #expect(try text(manifest) == before)
    }

    /// Mozilla's keys survive normalization, so the gecko ID and Firefox's own fields are still readable from the
    /// manifest Zigzag keeps. The kind that decides getBrowserInfo is the installed record's, not these keys.
    @Test func normalizingKeepsMozillasKeys() {
        let modern: [String: Any] = [
            "manifest_version": 3,
            "background": ["scripts": ["a.js"]],
            "browser_specific_settings": ["gecko": ["id": "modern@example.org"]],
        ]
        #expect(FirefoxManifest.isFirefox(modern))
        #expect(FirefoxManifest.isFirefox(FirefoxManifest.normalized(modern)))

        let older: [String: Any] = ["applications": ["gecko": ["id": "older@example.org"]]]
        #expect(FirefoxManifest.isFirefox(older))
        #expect(FirefoxManifest.isFirefox(FirefoxManifest.normalized(older)))

        #expect(!FirefoxManifest.isFirefox(["manifest_version": 2]))
    }
}

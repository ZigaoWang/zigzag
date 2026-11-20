import Foundation

/// A Firefox extension's manifest, made into the shape WebKit loads.
///
/// Firefox keeps several keys the Manifest V3 shape names differently: background scripts stay scripts instead of one
/// service worker, a sidebar is `sidebar_action` instead of `side_panel`, host matches stay among `permissions`, the
/// content security policy is one string, and web-accessible resources stay strings. WebKit takes the Chrome shape,
/// so the package is copied and this one copy is rewritten; the package's own manifest is never changed. Every
/// transform builds new values, so the same manifest comes out the same way however many times it is normalized.
nonisolated enum FirefoxManifest {
    /// Whether a manifest is a Firefox one: it carries the keys only Firefox writes, which firefox-polyfill.js gates
    /// on and the store records a package's kind by. The gecko ID itself is read by `XPIPackage`.
    static func isFirefox(_ manifest: [String: Any]) -> Bool {
        manifest["browser_specific_settings"] != nil || manifest["applications"] != nil
    }

    /// The manifest as WebKit loads it. The caller's dictionary and everything in it stay as they were.
    static func normalized(_ manifest: [String: Any]) -> [String: Any] {
        var out = manifest
        let version = (out["manifest_version"] as? NSNumber)?.intValue ?? 2

        // WebKit reads a toolbar button from Chrome's `action`. Firefox's MV2 calls it `browser_action`, and its
        // context-specific one `page_action`: copy it over when there is no `action`, or WebKit sees no popup and the
        // click falls through to whatever page the extension opens, flashing the popup first.
        if out["action"] == nil,
           let button = out["browser_action"] as? [String: Any] ?? out["page_action"] as? [String: Any] {
            out["action"] = button
        }

        // WebKit's side panel reads Chrome's key. Firefox's own stays beside it, with its title and icon.
        if let sidebar = out["sidebar_action"] as? [String: Any],
           let panel = sidebar["default_panel"] as? String, !panel.isEmpty,
           out["side_panel"] == nil {
            out["side_panel"] = ["default_path": panel]
        }

        if version >= 3 {
            // WebKit reads site access from host_permissions; Firefox keeps the patterns among permissions.
            movingHostPatterns(in: &out, from: "permissions", to: "host_permissions")
            movingHostPatterns(in: &out, from: "optional_permissions", to: "optional_host_permissions")
            // Firefox's MV3 policy is still one string, for extension pages.
            if let policy = out["content_security_policy"] as? String {
                out["content_security_policy"] = ["extension_pages": policy]
            }
        } else if let resources = out["web_accessible_resources"] as? [String], !resources.isEmpty {
            // Firefox's MV2 list is every page's: WebKit names the resources and the matches together.
            out["web_accessible_resources"] = [["resources": resources, "matches": ["<all_urls>"]]]
        }

        return out
    }

    /// A host match pattern rather than an API permission's name. Firefox allows patterns in both permission lists.
    private static func isHostPattern(_ name: String) -> Bool {
        name == "<all_urls>" || name.contains("://")
    }

    /// Moves the host patterns out of one permission list into the one WebKit reads, in their original order and
    /// without repeating one already there. API permission names stay put.
    private static func movingHostPatterns(in manifest: inout [String: Any], from key: String, to destination: String) {
        guard let requested = manifest[key] as? [String] else { return }
        let patterns = requested.filter(isHostPattern)
        guard !patterns.isEmpty else { return }
        var hosts = manifest[destination] as? [String] ?? []
        for pattern in patterns where !hosts.contains(pattern) { hosts.append(pattern) }
        manifest[destination] = hosts
        manifest[key] = requested.filter { !isHostPattern($0) }
    }

}

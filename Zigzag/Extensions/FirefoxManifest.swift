import Foundation

/// A Firefox extension's manifest, made into the shape WebKit loads.
///
/// Firefox keeps several keys the Manifest V3 shape names differently: background scripts stay scripts instead of one
/// service worker, a sidebar is `sidebar_action` instead of `side_panel`, host matches stay among `permissions`, the
/// content security policy is one string, and web-accessible resources stay strings. WebKit takes the Chrome shape,
/// so the package is copied and this one copy is rewritten; the package's own manifest is never changed. Every
/// transform builds new values, so the same manifest comes out the same way however many times it is normalized.
nonisolated enum FirefoxManifest {
    /// The worker the loaded copy runs where Firefox ran `background.scripts`.
    static let workerFile = "zigzag-firefox-worker.js"

    /// Whether a manifest is a Firefox one: it carries the keys only Firefox writes, which firefox-polyfill.js gates
    /// on and the store records a package's kind by. The gecko ID itself is read by `XPIPackage`.
    static func isFirefox(_ manifest: [String: Any]) -> Bool {
        manifest["browser_specific_settings"] != nil || manifest["applications"] != nil
    }

    /// The manifest as WebKit loads it. The caller's dictionary and everything in it stay as they were.
    static func normalized(_ manifest: [String: Any]) -> [String: Any] {
        var out = manifest
        let version = (out["manifest_version"] as? NSNumber)?.intValue ?? 2

        // Firefox's MV3 background is a list of scripts, as MV2's was. A package built for Chrome has the worker
        // already; one built for Firefox gets a worker that loads its scripts in order. A module worker imports
        // them, and only a module worker may say it is one.
        if version >= 3, var background = out["background"] as? [String: Any],
           let scripts = background["scripts"] as? [String], !scripts.isEmpty,
           background["service_worker"] == nil {
            background["service_worker"] = workerFile
            if (background["type"] as? String) != "module" {
                background.removeValue(forKey: "type")
            }
            out["background"] = background
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

    /// The worker's body: Firefox's scripts loaded in the order its manifest named them, as JavaScript strings. A
    /// module background imports each one instead, because `importScripts` is not available to a module worker.
    static func workerSource(scripts: [String], module: Bool = false) -> String {
        if module {
            return scripts.map { "import \"./\(escaped($0))\";\n" }.joined()
        }
        return "importScripts(\(scripts.map(quoted).joined(separator: ", ")));"
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

    /// One script path as a double-quoted JavaScript string, with the characters that would end it escaped.
    private static func quoted(_ script: String) -> String {
        "\"\(escaped(script))\""
    }

    /// A script path with the characters that would end a double-quoted JavaScript string escaped.
    private static func escaped(_ script: String) -> String {
        var escaped = ""
        for character in script {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
